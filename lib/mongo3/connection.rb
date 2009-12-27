module Mongo3
  class Connection
    
    def initialize( config_file )
      @config_file = config_file
    end

    def drop_db( path_names )
      path_name_tokens = path_names.split( "|" )
      env              = path_name_tokens[1]      
      connect_for( env ) do |con|
        db_name   = path_name_tokens.pop
        con.drop_database( db_name )
      end
    end

    def drop_cltn( path_names )
      path_name_tokens = path_names.split( "|" )
      env              = path_name_tokens[1]      
      connect_for( env ) do |con|
        cltn_name = path_name_tokens.pop
        db_name   = path_name_tokens.pop
        db        = con.db( db_name )
        cltn      = db[cltn_name]
        cltn.drop
      end
    end

    def clear_cltn( path_names )
      path_name_tokens = path_names.split( "|" )
      env              = path_name_tokens[1]      
      connect_for( env ) do |con|
        cltn_name = path_name_tokens.pop
        db_name   = path_name_tokens.pop
        db        = con.db( db_name )
        cltn      = db[cltn_name]
        cltn.remove
      end
    end
           
    def delete_row( path_names, id )
      path_name_tokens = path_names.split( "|" )
      env              = path_name_tokens[1]      
      connect_for( env ) do |con|
        cltn_name = path_name_tokens.pop
        db_name   = path_name_tokens.pop
        db        = con.db( db_name )
        cltn      = db[cltn_name]
        cltn.remove( {:_id => Mongo::ObjectID.from_string(id) } )
      end
    end
     
    def show( path_names )
      path_name_tokens = path_names.split( "|" )
      info             = OrderedHash.new
      env              = path_name_tokens[1]
      
      info[:title] = path_name_tokens.last
      if path_name_tokens.size == 2
        connect_for( env ) do |con|
          info[:name]        = env
          info[:host]        = con.host
          info[:port]        = con.port
          info[:databases]   = OrderedHash.new
          con.database_info.sort { |a,b| b[1] <=> a[1] }.each { |e| info[:databases][e[0]] = to_mb( e[1] ) }
          info[:server] = con.server_info
        end
      # BOZO !! Need to figure out links strategy!
      elsif path_name_tokens.size == 3
        db_name = path_name_tokens.pop
        info[:links] = OrderedHash.new
        connect_for( env ) do |con|          
          db = con.db( db_name )
          info[:links][:manage] = "/databases/1"
          # info[:links][:drop]   = "/databases/drop/"
          info[:size]        = to_mb( con.database_info[db_name] )
          info[:node]        = db.nodes
          info[:collections] = db.collection_names.size
          info[:error]       = db.error
          info[:last_status] = db.last_status
        end
      elsif path_name_tokens.size == 4
        info[:links] = OrderedHash.new        
        cltn_name = path_name_tokens.pop
        db_name   = path_name_tokens.pop
        connect_for( env ) do |con|
          db      = con.db( db_name )
          cltn    = db[cltn_name]
          indexes = db.index_information( cltn_name )
                    
          info[:links][:manage] = "/collections/1"
          # info[:links][:drop]   = "/collections/drop/"          
          info[:size]           = cltn.count
          info[:indexes]        = format_indexes( indexes ) if indexes and !indexes.empty?
        end
      end      
      info
    end

    def paginate_db( path_names, page=1, per_page=10 )
      path_name_tokens = path_names.split( "|" )
      env              = path_name_tokens[1]
      list             = nil
      connect_for( env ) do |con|
        db_name = path_name_tokens.pop
        db      = con.db( db_name )
        cltn    = db.collection_names.sort
        
        list = WillPaginate::Collection.create( page, per_page, cltn.size ) do |pager|
          offset = (page-1)*per_page
          names = cltn[offset..(offset+per_page)]
          cltns = []
          names.each do |name|
            list = db[name]
            row  = OrderedHash.new
            row[:name]  = name
            row[:count] = list.count
            cltns << row
          end          
          pager.replace( cltns ) 
        end        
      end
      list
    end
        
    def paginate_cltn( path_names, query_params=[{},[]], page=1, per_page=10 )
      path_name_tokens = path_names.split( "|" )
      env              = path_name_tokens[1]
      list             = nil
      connect_for( env ) do |con|
        cltn_name = path_name_tokens.pop
        db_name   = path_name_tokens.pop
        db        = con.db( db_name )
        cltn      = db[cltn_name]
        
        list = WillPaginate::Collection.create( page, per_page, cltn.count ) do |pager|
          offset = (page-1)*per_page
          sort   = query_params.last.empty? ? [ ['_id', Mongo::DESCENDING] ] : query_params.last
          pager.replace( cltn.find( query_params.first, 
            :sort  => sort,
            :skip  => offset, 
            :limit => per_page ).to_a)
        end        
      end
      list
    end
            
    # Fetch the environment landscape from the config file
    def landscape
      config
    end

    # Build environment tree
    def build_tree
      root = Node.make_node( "home" )
      
      # iterate thru envs
      id = 1
      config.each_pair do |env, info|
        node = Node.new( env, env, :dyna => true )
        root << node
        id += 1
      end
      root
    end

    # Build environment tree
    def build_partial_tree( path_names )
      path_name_tokens = path_names.split( "|" )      
      bm_env           = path_name_tokens[1]
      bm_cltn          = path_name_tokens.pop if path_name_tokens.size == 4
      bm_db            = path_name_tokens.pop if path_name_tokens.size == 3
      
      root = Node.make_node( "home" )
      
      # iterate thru envs
      config.each_pair do |env, info|
        node = Node.new( env, env, :dyna => true )
        root << node
        if node.name == bm_env
          connect_for( env ) do |con|      
            count = 0
            data  = { :dyna => true }
            con.database_names.each do |db_name|
              db      = con.db( db_name, :strict => true )
              cltns   = db.collection_names.size  
              db_node = Node.new( "#{env}_#{count}", "#{db_name}(#{cltns})", data.clone )
              node << db_node
              count += 1
              if bm_db and db_node.name =~ /^#{bm_db}/
                cltn_count = 0
                data = { :dyna => false }
                db.collection_names.each do |cltn_name|
                  size = db[cltn_name].count
                  cltn_node = Node.new( "#{db_name}_#{cltn_count}", "#{cltn_name}(#{size})", data.clone )
                  db_node << cltn_node
                  cltn_count += 1
                end              
              end
            end
          end
        end
      end
      root
    end
    
    # Build an appropriate subtree based on requested item
    def build_sub_tree( parent_id, path_names )
      path_name_tokens = path_names.split( "|" )
      env              = path_name_tokens[1]      
            
      if db_request?( path_name_tokens )
        sub_tree = build_db_tree( parent_id, env )
      else
        db_name  = path_name_tokens.last        
        sub_tree = build_cltn_tree( parent_id, env, db_name )
      end
      sub_tree.to_adjacencies
    end
        
    # Connects to host and spews out all available dbs
    # BOZO !! Need to deal with Auth?
    def build_db_tree( parent_id, env )    
      sub_root = nil
      connect_for( env ) do |con|      
        root = Node.make_node( "home" )
        sub_root = Node.new( parent_id, env )
      
        root << sub_root
      
        count = 0
        data  = { :dyna => true }
        con.database_names.each do |db_name|
          db    = con.db( db_name, :strict => true )
          cltns = db.collection_names.size  
          node  = Node.new( "#{env}_#{count}", "#{db_name}(#{cltns})", data.clone )
          sub_root << node
          count += 1
        end
      end
      sub_root
    end
    
    # Show collections
    def build_cltn_tree( parent_id, env, db_name ) 
      sub_root = nil
      connect_for( env ) do |con|
        db        = con.db( db_name )      
        root      = Node.make_node( "home" )
        env_node  = Node.make_node( env )
        sub_root  = Node.new( parent_id, db_name )
        root     << env_node
        env_node << sub_root
      
        count = 0
        data = { :dyna => false }
        db.collection_names.each do |cltn_name|
          size = db[cltn_name].count
          node = Node.new( "#{db_name}_#{count}", "#{cltn_name}(#{size})", data.clone )
          sub_root << node
          count += 1
        end
      end
      sub_root
    end
        
    # =========================================================================
    private
      
      # Connects to mongo given an environment
      # BOZO !! Auth... 
      def connect_for( env, &block )
        info = landscape[env]
        puts ">>> Connecting for #{env} -- #{info['host']}-#{info['port']}"
        con = Mongo::Connection.new( info['host'], info['port'] )
        
        if info['user'] and info['password']
          con.db( 'admin' ).authenticate( info['user'], info['password'] )
        end
        yield con
        con.close()
      end

      # db request occurs within dist 2
      def db_request?( path )
        path.size == 2
      end
    
      # cltn request occurs within dist 3
      def cltn_request?( path )
        path.size == 3
      end

      # Break down indexes in index + asc/desc   
      def format_indexes( indexes )
        formatted = {}
        indexes.each_pair do |key, values|
          buff = []
          values.each do |pair|
            buff << "#{pair.first} [#{pair.last}]"
          end
          formatted[key] = buff
        end  
        formatted    
      end
   
      # Convert size to mb
      def to_mb( val )
        return val if val < 1_000_000
        "#{format_number(val/1_000_000)}Mb"
      end
   
      # Add thousand markers
      def format_number( numb )
        numb.to_s.gsub(/(\d)(?=\d{3}+(\.\d*)?$)/, '\1,')
      end
        
      # Initialize the mongo installation landscape
      def config
        unless @config
          @config = YAML.load_file( @config_file )
        end
        @config
      end
            
  end
end