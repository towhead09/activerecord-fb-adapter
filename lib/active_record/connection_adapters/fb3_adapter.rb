# Rails 3-specific database adapter for Firebird (http://firebirdsql.org)
# Author: Brent Rowland <rowland@rowlandresearch.com>
# Based originally on FireRuby extension by Ken Kunz <kennethkunz@gmail.com>

require 'active_record/connection_adapters/abstract_adapter'
require 'base64'

module ActiveRecord
  class << Base
    def fb_connection(config) # :nodoc:
      config = config.symbolize_keys.merge(:downcase_names => true)
      unless config.has_key?(:database)
        raise ArgumentError, "No database specified. Missing argument: database."
      end      
      config[:database] = File.expand_path(config[:database]) if config[:host] =~ /localhost/i
      config[:database] = "#{config[:host]}/#{config[:port] || 3050}:#{config[:database]}" if config[:host]
      require_library_or_gem 'fb'
      db = Fb::Database.new(config)
      begin
        connection = db.connect
      rescue
        require_library_or_gem 'pp'
        pp config unless config[:create]
        connection = config[:create] ? db.create.connect : (raise ConnectionNotEstablished, "No Firebird connections established.")
      end
      ConnectionAdapters::Fb3Adapter.new(connection, logger, config)
    end
  end

  module ConnectionAdapters # :nodoc:
    # The Fb adapter relies on the Fb extension.
    #
    # == Usage Notes
    #
    # === Sequence (Generator) Names
    # The Fb adapter supports the same approach adopted for the Oracle
    # adapter. See ActiveRecord::Base#set_sequence_name for more details.
    #
    # Note that in general there is no need to create a <tt>BEFORE INSERT</tt>
    # trigger corresponding to a Firebird sequence generator when using
    # ActiveRecord. In other words, you don't have to try to make Firebird
    # simulate an <tt>AUTO_INCREMENT</tt> or +IDENTITY+ column. When saving a
    # new record, ActiveRecord pre-fetches the next sequence value for the table
    # and explicitly includes it in the +INSERT+ statement. (Pre-fetching the
    # next primary key value is the only reliable method for the Fb
    # adapter to report back the +id+ after a successful insert.)
    #
    # === BOOLEAN Domain
    # Firebird 1.5 does not provide a native +BOOLEAN+ type. But you can easily
    # define a +BOOLEAN+ _domain_ for this purpose, e.g.:
    #
    #  CREATE DOMAIN D_BOOLEAN AS SMALLINT CHECK (VALUE IN (0, 1));
    #
    # When the Fb adapter encounters a column that is based on a domain
    # that includes "BOOLEAN" in the domain name, it will attempt to treat
    # the column as a +BOOLEAN+.
    #
    # By default, the Fb adapter will assume that the BOOLEAN domain is
    # defined as above.  This can be modified if needed.  For example, if you
    # have a legacy schema with the following +BOOLEAN+ domain defined:
    #
    #  CREATE DOMAIN BOOLEAN AS CHAR(1) CHECK (VALUE IN ('T', 'F'));
    #
    # ...you can add the following line to your <tt>environment.rb</tt> file:
    #
    #  ActiveRecord::ConnectionAdapters::Fb.boolean_domain = { :true => 'T', :false => 'F' }
    #
    # === Column Name Case Semantics
    # Firebird and ActiveRecord have somewhat conflicting case semantics for
    # column names.
    #
    # [*Firebird*]
    #   The standard practice is to use unquoted column names, which can be
    #   thought of as case-insensitive. (In fact, Firebird converts them to
    #   uppercase.) Quoted column names (not typically used) are case-sensitive.
    # [*ActiveRecord*]
    #   Attribute accessors corresponding to column names are case-sensitive.
    #   The defaults for primary key and inheritance columns are lowercase, and
    #   in general, people use lowercase attribute names.
    #
    # In order to map between the differing semantics in a way that conforms
    # to common usage for both Firebird and ActiveRecord, uppercase column names
    # in Firebird are converted to lowercase attribute names in ActiveRecord,
    # and vice-versa. Mixed-case column names retain their case in both
    # directions. Lowercase (quoted) Firebird column names are not supported.
    # This is similar to the solutions adopted by other adapters.
    #
    # In general, the best approach is to use unquoted (case-insensitive) column
    # names in your Firebird DDL (or if you must quote, use uppercase column
    # names). These will correspond to lowercase attributes in ActiveRecord.
    #
    # For example, a Firebird table based on the following DDL:
    #
    #  CREATE TABLE products (
    #    id BIGINT NOT NULL PRIMARY KEY,
    #    "TYPE" VARCHAR(50),
    #    name VARCHAR(255) );
    #
    # ...will correspond to an ActiveRecord model class called +Product+ with
    # the following attributes: +id+, +type+, +name+.
    #
    # ==== Quoting <tt>"TYPE"</tt> and other Firebird reserved words:
    # In ActiveRecord, the default inheritance column name is +type+. The word
    # _type_ is a Firebird reserved word, so it must be quoted in any Firebird
    # SQL statements. Because of the case mapping described above, you should
    # always reference this column using quoted-uppercase syntax
    # (<tt>"TYPE"</tt>) within Firebird DDL or other SQL statements (as in the
    # example above). This holds true for any other Firebird reserved words used
    # as column names as well.
    #
    # === Migrations
    # The Fb adapter does not currently support Migrations.
    #
    # == Connection Options
    # The following options are supported by the Fb adapter.
    #
    # <tt>:database</tt>::
    #   <i>Required option.</i> Specifies one of: (i) a Firebird database alias;
    #   (ii) the full path of a database file; _or_ (iii) a full Firebird
    #   connection string. <i>Do not specify <tt>:host</tt>, <tt>:service</tt>
    #   or <tt>:port</tt> as separate options when using a full connection
    #   string.</i>
    # <tt>:username</tt>::
    #   Specifies the database user. Defaults to 'sysdba'.
    # <tt>:password</tt>::
    #   Specifies the database password. Defaults to 'masterkey'.
    # <tt>:charset</tt>::
    #   Specifies the character set to be used by the connection. Refer to the
    #   Firebird documentation for valid options.
    class Fb3Adapter < AbstractAdapter
      @@boolean_domain = { :true => 1, :false => 0 }
      cattr_accessor :boolean_domain

      def initialize(connection, logger, connection_params=nil)
        super(connection, logger)
        @connection_params = connection_params
      end

      # Returns the human-readable name of the adapter.  Use mixed case - one
      # can always use downcase if needed.
      def adapter_name
        'Fb3'
      end

      # Does this adapter support migrations?  Backend specific, as the
      # abstract adapter always returns +false+.
      def supports_migrations?
        true
      end

      # Can this adapter determine the primary key for tables not attached
      # to an Active Record class, such as join tables?  Backend specific, as
      # the abstract adapter always returns +false+.
      def supports_primary_key?
        false
      end

      # Does this adapter support using DISTINCT within COUNT?  This is +true+
      # for all adapters except sqlite.
      def supports_count_distinct?
        true
      end

      # Does this adapter support DDL rollbacks in transactions?  That is, would
      # CREATE TABLE or ALTER TABLE get rolled back by a transaction?  PostgreSQL,
      # SQL Server, and others support this.  MySQL and others do not.
      def supports_ddl_transactions?
        false
      end

      # Does this adapter support savepoints? PostgreSQL and MySQL do, SQLite
      # does not.
      def supports_savepoints?
        true
      end

      # Should primary key values be selected from their corresponding
      # sequence before the insert statement?  If true, next_sequence_value
      # is called before each insert to set the record's primary key.
      # This is false for all adapters but Firebird.
      def prefetch_primary_key?(table_name = nil)
        true
      end

      # Does this adapter restrict the number of ids you can use in a list. Oracle has a limit of 1000.
      def ids_in_list_limit
        1499
      end

      # QUOTING ==================================================

      # Override to return the quoted table name. Defaults to column quoting.
      # def quote_table_name(name)
      #   quote_column_name(name)
      # end

      # REFERENTIAL INTEGRITY ====================================

      # Override to turn off referential integrity while executing <tt>&block</tt>.
      # def disable_referential_integrity
      #   yield
      # end

      # CONNECTION MANAGEMENT ====================================

      # Checks whether the connection to the database is still active. This includes
      # checking whether the database is actually capable of responding, i.e. whether
      # the connection isn't stale.
      def active?
        @connection.open?
      end

      # Disconnects from the database if already connected, and establishes a
      # new connection with the database.
      def reconnect!
        disconnect!
        @connection = Fb::Database.connect(@connection_params)
      end

      # Disconnects from the database if already connected. Otherwise, this
      # method does nothing.
      def disconnect!
        @connection.close rescue nil
      end

      # Reset the state of this connection, directing the DBMS to clear
      # transactions and other connection-related server-side state. Usually a
      # database-dependent operation.
      #
      # The default implementation does nothing; the implementation should be
      # overridden by concrete adapters.
      def reset!
        reconnect!
      end

      # Returns true if its required to reload the connection between requests for development mode.
      # This is not the case for Ruby/MySQL and it's not necessary for any adapters except SQLite.
      # def requires_reloading?
      #   false
      # end

      # Checks whether the connection to the database is still active (i.e. not stale).
      # This is done under the hood by calling <tt>active?</tt>. If the connection
      # is no longer active, then this method will reconnect to the database.
      # def verify!(*ignored)
      #   reconnect! unless active?
      # end

      # Provides access to the underlying database driver for this adapter. For
      # example, this method returns a Mysql object in case of MysqlAdapter,
      # and a PGconn object in case of PostgreSQLAdapter.
      #
      # This is useful for when you need to call a proprietary method such as
      # PostgreSQL's lo_* methods.
      # def raw_connection
      #   @connection
      # end

      # def open_transactions
      #   @open_transactions ||= 0
      # end

      # def increment_open_transactions
      #   @open_transactions ||= 0
      #   @open_transactions += 1
      # end

      # def decrement_open_transactions
      #   @open_transactions -= 1
      # end

      # def transaction_joinable=(joinable)
      #   @transaction_joinable = joinable
      # end

      def create_savepoint
        execute("SAVEPOINT #{current_savepoint_name}")
      end

      def rollback_to_savepoint
        execute("ROLLBACK TO SAVEPOINT #{current_savepoint_name}")
      end

      def release_savepoint
        execute("RELEASE SAVEPOINT #{current_savepoint_name}")
      end

      # def current_savepoint_name
      #   "active_record_#{open_transactions}"
      # end

    protected
      def expand(sql, args)
        sql + ', ' + args * ', '
      end

      def log(sql, args, name, &block)
        super(expand(sql, args), name, &block)
      end

      def translate_exception(e, message)
        case e.message
        when /violation of FOREIGN KEY constraint/
          InvalidForeignKey.new(message, exception)
        when /violation of PRIMARY or UNIQUE KEY constraint/
          RecordNotUnique.new(message, exception)
        else
          super
        end
      end

    public
      # from module Quoting
      def quote(value, column = nil)
        # records are quoted as their primary key
        return value.quoted_id if value.respond_to?(:quoted_id)

        case value
        when String, ActiveSupport::Multibyte::Chars
          value = value.to_s
          if column && [:integer, :float].include?(column.type)
            value = column.type == :integer ? value.to_i : value.to_f
            value.to_s
          else
            "@#{Base64.encode64(value).chop}@"
          end
        when NilClass              then "NULL"
        when TrueClass             then (column && column.type == :integer ? '1' : quoted_true)
        when FalseClass            then (column && column.type == :integer ? '0' : quoted_false)
        when Float, Fixnum, Bignum then value.to_s
        # BigDecimals need to be output in a non-normalized form and quoted.
        when BigDecimal            then value.to_s('F')
        when Symbol                then "'#{quote_string(value.to_s)}'"
        else
          if value.acts_like?(:date)
            quote_date(value)
          elsif value.acts_like?(:time)
            quote_timestamp(value)
          else
            quote_object(value)
          end
        end
      end

      def quote_date(value)
        "@#{Base64.encode64(value.strftime('%Y-%m-%d')).chop}@"
      end

      def quote_timestamp(value)
        zone_conversion_method = ActiveRecord::Base.default_timezone == :utc ? :getutc : :getlocal
        value = value.respond_to?(zone_conversion_method) ? value.send(zone_conversion_method) : value
        "@#{Base64.encode64(value.strftime('%Y-%m-%d %H:%M:%S')).chop}@"
      end

      def quote_string(string) # :nodoc:
        string.gsub(/'/, "''")
      end

      def quote_object(obj)
        if obj.respond_to?(:to_str)
          "@#{Base64.encode64(obj.to_str).chop}@"
        else
          "@#{Base64.encode64(obj.to_yaml).chop}@"
        end
      end

      def quote_column_name(column_name) # :nodoc:
        %Q("#{ar_to_fb_case(column_name.to_s)}")
      end

      # Quotes the table name. Defaults to column name quoting.
      # def quote_table_name(table_name)
      #   quote_column_name(table_name)
      # end

      def quoted_true # :nodoc:
        quote(boolean_domain[:true])
      end

      def quoted_false # :nodoc:
        quote(boolean_domain[:false])
      end

    private
      # Maps uppercase Firebird column names to lowercase for ActiveRecord;
      # mixed-case columns retain their original case.
      def fb_to_ar_case(column_name)
        column_name =~ /[[:lower:]]/ ? column_name : column_name.downcase
      end

      # Maps lowercase ActiveRecord column names to uppercase for Fierbird;
      # mixed-case columns retain their original case.
      def ar_to_fb_case(column_name)
        column_name =~ /[[:upper:]]/ ? column_name : column_name.upcase
      end

    public
      # from module DatabaseStatements

      # Returns an array of record hashes with the column names as keys and
      # column values as values.
      def select_all(sql, name = nil, format = :hash) # :nodoc:
        translate(sql) do |sql, args|
          log(sql, args, name) do
            @connection.query(format, sql, *args)
          end
        end
      end

      # Returns a record hash with the column names as keys and column values
      # as values.
      def select_one(sql, name = nil, format = :hash) # :nodoc:
        translate(sql) do |sql, args|
          log(sql, args, name) do
            @connection.query(format, sql, *args).first
          end
        end
      end

      # Returns an array of arrays containing the field values.
      # Order is the same as that returned by +columns+.
      def select_rows(sql, name = nil)
        select_all(sql, name, :array)
      end

      # Executes the SQL statement in the context of this connection.
      def execute(sql, name = nil, skip_logging = false)
        translate(sql) do |sql, args|
          if (name == :skip_logging) or skip_logging
            @connection.execute(sql, *args)
          else
            log(sql, args, name) do
              @connection.execute(sql, *args)
            end
          end
        end
      end

      # Returns the last auto-generated ID from the affected table.
      def insert(sql, name = nil, pk = nil, id_value = nil, sequence_name = nil)
        execute(sql, name)
        id_value
      end

      # Executes the update statement and returns the number of rows affected.
      alias_method :update, :execute
      # def update(sql, name = nil)
      #   update_sql(sql, name)
      # end

      # Executes the delete statement and returns the number of rows affected.
      alias_method :delete, :execute
      # def delete(sql, name = nil)
      #   delete_sql(sql, name)
      # end

      # Checks whether there is currently no transaction active. This is done
      # by querying the database driver, and does not use the transaction
      # house-keeping information recorded by #increment_open_transactions and
      # friends.
      #
      # Returns true if there is no transaction active, false if there is a
      # transaction active, and nil if this information is unknown.
      def outside_transaction?
        !@connection.transaction_started
      end

      # Begins the transaction (and turns off auto-committing).
      def begin_db_transaction
        @transaction = @connection.transaction('READ COMMITTED')
      end

      # Commits the transaction (and turns on auto-committing).
      def commit_db_transaction
        @transaction = @connection.commit
      end

      # Rolls back the transaction (and turns on auto-committing). Must be
      # done if the transaction block raises an exception or returns false.
      def rollback_db_transaction
        @transaction = @connection.rollback
      end

      # Appends +LIMIT+ and +OFFSET+ options to an SQL statement, or some SQL
      # fragment that has the same semantics as LIMIT and OFFSET.
      #
      # +options+ must be a Hash which contains a +:limit+ option
      # and an +:offset+ option.
      #
      # This method *modifies* the +sql+ parameter.
      #
      # ===== Examples
      #  add_limit_offset!('SELECT * FROM suppliers', {:limit => 10, :offset => 50})
      # generates
      #  SELECT * FROM suppliers LIMIT 10 OFFSET 50
      def add_limit_offset!(sql, options) # :nodoc:
        if limit = options[:limit]
          if offset = options[:offset]
            sql << " ROWS #{offset.to_i + 1} TO #{offset.to_i + limit.to_i}"
          else
            sql << " ROWS #{limit.to_i}"
          end
        end
        sql
      end

      def default_sequence_name(table, column)
        "#{table_name}_seq"
      end

      # Set the sequence to the max value of the table's column.
      def reset_sequence!(table, column, sequence = nil)
        max_id = select_value("select max(#{column}) from #{table}")
        execute("alter sequence #{default_sequence_name(table, column)} restart with #{max_id}")
      end

      # Inserts the given fixture into the table. Overridden in adapters that require
      # something beyond a simple insert (eg. Oracle).
      # def insert_fixture(fixture, table_name)
      #   execute "INSERT INTO #{quote_table_name(table_name)} (#{fixture.key_list}) VALUES (#{fixture.value_list})", 'Fixture Insert'
      # end

      # def empty_insert_statement_value
      #   "VALUES(DEFAULT)"
      # end

      # def case_sensitive_equality_operator
      #   "="
      # end

    protected
      # Returns an array of record hashes with the column names as keys and
      # column values as values.
      def select(sql, name = nil)
        select_all(sql, name, :array)
      end
    end
  end
end