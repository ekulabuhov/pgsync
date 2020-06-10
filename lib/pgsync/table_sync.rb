module PgSync
  class TableSync
    include Utils

    attr_reader :source, :destination, :tasks, :opts, :resolver

    def initialize(source:, destination:, tasks:, opts:, resolver:)
      @source = source
      @destination = destination
      @tasks = tasks
      @opts = opts
      @resolver = resolver
    end

    def perform
      confirm_tables_exist(destination, tasks, "destination")

      add_columns

      add_triggers if triggers?

      show_notes

      # don't sync tables with no shared fields
      # we show a warning message above
      run_tasks(tasks.reject { |task| task.shared_fields.empty? })
    end

    # TODO only query specific tables
    # TODO add sequences, primary keys, etc
    def add_columns
      source_columns = columns(source)
      destination_columns = columns(destination)

      tasks.each do |task|
        task.from_columns = source_columns[task.table] || []
        task.to_columns = destination_columns[task.table] || []
      end
    end

    def add_triggers
      destination_triggers = triggers(destination)

      tasks.each do |task|
        task.to_triggers = destination_triggers[task.table] || []
      end
    end

    def show_notes
      # for tables
      resolver.notes.each do |note|
        warning note
      end

      # for columns and sequences
      tasks.each do |task|
        task.notes.each do |note|
          warning "#{task_name(task)}: #{note}"
        end
      end

      # for non-deferrable constraints
      if opts[:defer_constraints]
        constraints = non_deferrable_constraints(destination)
        constraints = tasks.flat_map { |t| constraints[t.table] || [] }
        warning "Non-deferrable constraints: #{constraints.join(", ")}" if constraints.any?
      end
    end

    def columns(data_source)
      query = <<~SQL
        SELECT
          table_schema AS schema,
          table_name AS table,
          column_name AS column,
          data_type AS type
        FROM
          information_schema.columns
        ORDER BY 1, 2, 3
      SQL
      data_source.execute(query).group_by { |r| Table.new(r["schema"], r["table"]) }.map do |k, v|
        [k, v.map { |r| {name: r["column"], type: r["type"]} }]
      end.to_h
    end

    def triggers(data_source)
      query = <<~SQL
        SELECT
          nspname AS schema,
          relname AS table,
          tgname AS name,
          tgisinternal AS internal,
          tgenabled != 'D' AS enabled,
          tgconstraint != 0 AS integrity
        FROM
          pg_trigger
        INNER JOIN
          pg_class ON pg_class.oid = pg_trigger.tgrelid
        INNER JOIN
          pg_namespace ON pg_namespace.oid = pg_class.relnamespace
      SQL
      data_source.execute(query).group_by { |r| Table.new(r["schema"], r["table"]) }.to_h
    end

    def non_deferrable_constraints(data_source)
      query = <<~SQL
        SELECT
          table_schema AS schema,
          table_name AS table,
          constraint_name
        FROM
          information_schema.table_constraints
        WHERE
          constraint_type = 'FOREIGN KEY' AND
          is_deferrable = 'NO'
      SQL
      data_source.execute(query).group_by { |r| Table.new(r["schema"], r["table"]) }.map do |k, v|
        [k, v.map { |r| r["constraint_name"] }]
      end.to_h
    end

    def triggers?
      opts[:disable_user_triggers] || opts[:disable_integrity]
    end

    def run_tasks(tasks, &block)
      notices = []
      failed_tables = []

      spinners = TTY::Spinner::Multi.new(format: :dots, output: output)
      task_spinners = {}
      started_at = {}

      start = lambda do |task, i|
        message = ":spinner #{display_item(task)}"
        spinner = spinners.register(message)
        if opts[:in_batches]
          # log instead of spin for non-tty
          log message.sub(":spinner", "⠋")
        else
          spinner.auto_spin
        end
        task_spinners[task] = spinner
        started_at[task] = Time.now
      end

      finish = lambda do |task, i, result|
        spinner = task_spinners[task]
        time = (Time.now - started_at[task]).round(1)

        message =
          if result[:message]
            "(#{result[:message].lines.first.to_s.strip})"
          else
            "- #{time}s"
          end

        notices.concat(result[:notices])

        if result[:status] == "success"
          spinner.success(message)
        else
          spinner.error(message)
          failed_tables << task_name(task)
          fail_sync(failed_tables) if opts[:fail_fast]
        end

        unless spinner.send(:tty?)
          status = result[:status] == "success" ? "✔" : "✖"
          log [status, display_item(task), message].join(" ")
        end
      end

      options = {start: start, finish: finish}

      jobs = opts[:jobs]
      if opts[:debug] || opts[:in_batches] || opts[:defer_constraints] || opts[:defer_constraints_v2] || opts[:disable_integrity] || opts[:disable_integrity_v2]
        warning "--jobs ignored" if jobs
        jobs = 0
      end

      if windows?
        options[:in_threads] = jobs || 4
      else
        options[:in_processes] = jobs if jobs
      end

      maybe_defer_constraints do
        # could try to use `raise Parallel::Kill` to fail faster with --fail-fast
        # see `fast_faster` branch
        # however, need to make sure connections are cleaned up properly
        Parallel.each(tasks, **options) do |task|
          source.reconnect_if_needed
          destination.reconnect_if_needed

          task.perform
        end
      end

      notices.each do |notice|
        warning notice
      end

      fail_sync(failed_tables) if failed_tables.any?
    end

    def maybe_defer_constraints
      disable_integrity = opts[:disable_integrity] || opts[:disable_integrity_v2]
      defer_constraints = opts[:defer_constraints] || opts[:defer_constraints_v2]

      if disable_integrity || defer_constraints
        destination.transaction do
          restore_triggers = false

          if disable_integrity
            # both --disable-integrity options require superuser privileges
            # however, only v2 works on Amazon RDS, which added specific support for it
            # https://aws.amazon.com/about-aws/whats-new/2014/11/10/amazon-rds-postgresql-read-replicas/
            #
            # session_replication_role disables more than foreign keys (like triggers and rules)
            # this is probably fine, but keep the current default for now
            if opts[:disable_integrity_v2] || (opts[:disable_integrity] && rds?)
              # SET LOCAL lasts until the end of the transaction
              # https://www.postgresql.org/docs/current/sql-set.html
              destination.execute("SET LOCAL session_replication_role = replica")
            else
              update_integrity_triggers(tasks, "DISABLE")
              restore_triggers = true
            end
          else
           if opts[:defer_constraints_v2]
              table_constraints = non_deferrable_constraints(destination)
              table_constraints.each do |table, constraints|
                constraints.each do |constraint|
                  destination.execute("ALTER TABLE #{quote_ident_full(table)} ALTER CONSTRAINT #{quote_ident(constraint)} DEFERRABLE")
                end
              end
            end

            destination.execute("SET CONSTRAINTS ALL DEFERRED")
          end

          source.transaction do
            yield
          end

          # set them back
          if opts[:defer_constraints_v2]
            destination.execute("SET CONSTRAINTS ALL IMMEDIATE")

            table_constraints.each do |table, constraints|
              constraints.each do |constraint|
                destination.execute("ALTER TABLE #{quote_ident_full(table)} ALTER CONSTRAINT #{quote_ident(constraint)} NOT DEFERRABLE")
              end
            end
          end

          update_integrity_triggers(tasks, "ENABLE") if restore_triggers
        end
      else
        yield
      end
    end

    def update_integrity_triggers(tasks, op)
      tasks.each do |task|
        task.integrity_triggers.each do |trigger|
          destination.execute("ALTER TABLE #{quote_ident_full(task.table)} #{op} TRIGGER #{quote_ident(trigger["name"])}")
        end
      end
    end

    def rds?
      destination.execute("SELECT name, setting FROM pg_settings WHERE name LIKE 'rds.%'").any?
    end

    def fail_sync(failed_tables)
      raise Error, "Sync failed for #{failed_tables.size} table#{failed_tables.size == 1 ? nil : "s"}: #{failed_tables.join(", ")}"
    end

    def display_item(item)
      messages = []
      messages << task_name(item)
      messages << item.opts[:sql] if item.opts[:sql]
      messages.join(" ")
    end

    def windows?
      Gem.win_platform?
    end
  end
end
