require 'digest/sha1'
require 'mysql2'
require 'sinatra/base'
require 'hiredis'
require 'redis'
require 'timeout'

class AwesomeFetch
  STREAM_KEY = 'isubata:stream:message'

  def self.instance
    @instance ||= AwesomeFetch.new.tap(&:start)
  end

  def initialize()
    @subscribers = {}
    @lock = Mutex.new
  end

  def wait(timeout: 5)
    @lock.synchronize do
      @subscribers[Thread.current] = true
    end
    sleep timeout
  ensure
    @lock.synchronize do
      @subscribers.delete(Thread.current)
    end
  end

  def connect_redis
    Redis.new(url: ENV.fetch('ISUBATA_REDIS_URL', 'redis://localhost:6379/0'))
  end

  def start
    @thread = Thread.new do
      redis = connect_redis()
      redis.subscribe(STREAM_KEY) do |on|
        on.subscribe do |ch, subs|
          puts "AwesomeFetch subscribed to #{ch.inspect} (#{subs} subscriptions)"
        end

        on.message do |ch, message|
          payload = message.empty? ? nil : MessagePack.unpack(message)
          on_payload(payload)
        end
      end
    rescue Exception => e
      $stderr.puts "AwesomeFetch ERROR: #{e.inspect}\n\t#{e.backtrace.join("\n\t")}"
      sleep 1
      retry
    end.tap do |th|
      th.abort_on_exception = true
    end
  end

  def on_payload(payload)
    @subscribers.dup.each_key do |th|
      th.wakeup
    end
  end
end

AwesomeFetch.instance.start

# AwesomeFetch.

module MysqlMonkeyPatch
  def logger
    @logger ||= VanillaLogger.new('/tmp/isu-query.log')
  end

  def xquery(query, *args)
    s = Time.now
    r = super
    e = Time.now

    c0 = caller_locations[0]
    c1 = caller_locations[1]

    cstr0 = "#{File.basename(c0.path)}:#{c0.lineno}:#{c0.label}" if c0
    cstr1 = "#{File.basename(c1.path)}:#{c1.lineno}:#{c1.label}" if c1

    logger.write "type:mysql\tmode:xquery\tms:#{(e-s) * 1000}\tquery:#{query}\targs:#{args.inspect}\tcaller0:#{cstr0}\tcaller1:#{cstr1}\n"
    r
  end

  def query(query, *args)
    s = Time.now
    r = super
    e = Time.now

    c0 = caller_locations[0]
    return r if c0.label == 'xquery'.freeze

    c1 = caller_locations[1]
    cstr0 = "#{File.basename(c0.path)}:#{c0.lineno}:#{c0.label}" if c0
    cstr1 = "#{File.basename(c1.path)}:#{c1.lineno}:#{c1.label}" if c1

    logger.write "type:mysql\tmode:query\tms:#{(e-s) * 1000}\tquery:#{query}\targs:#{args.inspect}\tcaller0:#{cstr0}\tcaller1:#{cstr1}\n"
    r
  end

end

class App < Sinatra::Base
  configure do
    set :session_secret, 'tonymoris'
    set :public_folder, File.expand_path('../../public', __FILE__)
    set :avatar_max_size, 1 * 1024 * 1024

    enable :sessions
  end

  configure :development do
    require 'sinatra/reloader'
    register Sinatra::Reloader
  end

  helpers do
    def user
      return @_user unless @_user.nil?

      user_id = session[:user_id]
      return nil if user_id.nil?

      @_user = db_get_user(user_id)
      if @_user.nil?
        params[:user_id] = nil
        return nil
      end

      @_user
    end
  end

  get '/initialize' do
    redis.keys('isubata:*').each_slice(100) do |ks|
      redis.del(*ks)
    end

    db.query("DELETE FROM user WHERE id > 1000")
    db.query("DELETE FROM image WHERE id > 1001")
    db.query("DELETE FROM channel WHERE id > 10")
    db.query("DELETE FROM message WHERE id > 10000")
    db.query("DELETE FROM haveread")

    channel_ids = db.query('SELECT id FROM channel').to_a.map { |_| _['id'] }
    channel_ids.each do |ch|
      statement = db.prepare('SELECT COUNT(*) as cnt FROM message WHERE channel_id = ?')
      cnt = statement.execute(ch).first['cnt']
      statement.close
      redis.hset(redis_key_total_messages, ch, cnt)
    end

    204
  end

  get '/' do
    if session.has_key?(:user_id)
      return redirect '/channel/1', 303
    end
    erb :index
  end

  get '/channel/:channel_id' do
    if user.nil?
      return redirect '/login', 303
    end

    @channel_id = params[:channel_id].to_i
    @channels, @description = get_channel_list_info(@channel_id)
    session[:bakusoku] = true
    erb :channel
  end

  get '/register' do
    erb :register
  end

  post '/register' do
    name = params[:name]
    pw = params[:password]
    if name.nil? || name.empty? || pw.nil? || pw.empty?
      return 400
    end
    begin
      user_id = register(name, pw)
    rescue Mysql2::Error => e
      return 409 if e.error_number == 1062
      raise e
    end
    session[:user_id] = user_id
    redirect '/', 303
  end

  get '/login' do
    erb :login
  end

  post '/login' do
    name = params[:name]
    statement = db.prepare('SELECT * FROM user WHERE name = ?')
    row = statement.execute(name).first
    statement.close
    if row.nil? || row['password'] != Digest::SHA1.hexdigest(row['salt'] + params[:password])
      return 403
    end
    session[:user_id] = row['id']
    session[:bakusoku] = true
    redirect '/', 303
  end

  get '/logout' do
    session[:user_id] = nil
    redirect '/', 303
  end

  post '/message' do
    user_id = session[:user_id]
    message = params[:message]
    channel_id = params[:channel_id]
    if user_id.nil? || message.nil? || channel_id.nil? || user.nil?
      return 403
    end
    db_add_message(channel_id.to_i, user_id, message)
    204
  end

  get '/message' do
    user_id = session[:user_id]
    if user_id.nil?
      return 403
    end

    channel_id = params[:channel_id].to_i
    last_message_id = params[:last_message_id].to_i
    statement = db.prepare('SELECT * FROM message WHERE id > ? AND channel_id = ? ORDER BY id DESC LIMIT 100')
    rows = statement.execute(last_message_id, channel_id).to_a
    statement.close
    users = get_users(rows.map { |r| r['user_id'] }.uniq)
    response = []
    rows.each do |row|
      r = {}
      r['id'] = row['id']
      # statement = db.prepare('SELECT name, display_name, avatar_icon FROM user WHERE id = ?')
      r['user'] = users[row['user_id']] # statement.execute(row['user_id']).first
      r['date'] = row['created_at'].strftime("%Y/%m/%d %H:%M:%S")
      r['content'] = row['content']
      response << r
      # statement.close
    end
    response.reverse!

    max_message_id = rows.empty? ? 0 : rows.map {  |row| row['id'] }.max
    redis.hset(redis_key_lastreads(user_id), channel_id, max_message_id)

    content_type :json
    response.to_json
  end

  get '/fetch' do
    user_id = session[:user_id]
    if user_id.nil?
      return 403
    end

    unless session.delete(:bakusoku)
      AwesomeFetch.instance.wait
    end

    rs = redis.hgetall(redis_key_total_messages)

    redis.hgetall(redis_key_lastreads(user_id)).each do |ch, last|
      statement = db.prepare('SELECT COUNT(*) as cnt FROM message WHERE channel_id = ? AND ? < id')
      unread = statement.execute(ch, last).first['cnt']
      statement.close

      rs[ch.to_s] = unread
    end

    r = rs.map do |ch, unread|
      {
        'channel_id' => ch.to_i,
        'unread' => unread.to_i,
      }
    end

    content_type :json
    r.to_json
  end

  get '/history/:channel_id' do
    if user.nil?
      return redirect '/login', 303
    end

    @channel_id = params[:channel_id].to_i

    @page = params[:page]
    if @page.nil?
      @page = '1'
    end
    if @page !~ /\A\d+\Z/ || @page == '0'
      return 400
    end
    @page = @page.to_i

    n = 20
    statement = db.prepare('SELECT * FROM message WHERE channel_id = ? ORDER BY id DESC LIMIT ? OFFSET ?')
    rows = statement.execute(@channel_id, n, (@page - 1) * n).to_a
    statement.close
    users = get_users(rows.map { |r| r['user_id'] }.uniq)
    @messages = []
    rows.each do |row|
      r = {}
      r['id'] = row['id']
      # statement = db.prepare('SELECT name, display_name, avatar_icon FROM user WHERE id = ?')
      r['user'] = users[row['user_id']] # statement.execute(row['user_id']).first
      r['date'] = row['created_at'].strftime("%Y/%m/%d %H:%M:%S")
      r['content'] = row['content']
      @messages << r
      # statement.close
    end
    @messages.reverse!

    statement = db.prepare('SELECT COUNT(*) as cnt FROM message WHERE channel_id = ?')
    cnt = statement.execute(@channel_id).first['cnt'].to_f
    statement.close
    @max_page = cnt == 0 ? 1 : (cnt / n).ceil

    return 400 if @page > @max_page

    @channels, @description = get_channel_list_info(@channel_id)
    session[:bakusoku] = true
    erb :history
  end

  get '/profile/:user_name' do
    if user.nil?
      return redirect '/login', 303
    end

    @channels, = get_channel_list_info

    user_name = params[:user_name]
    statement = db.prepare('SELECT * FROM user WHERE name = ?')
    @user = statement.execute(user_name).first
    statement.close

    if @user.nil?
      return 404
    end

    @self_profile = user['id'] == @user['id']
    erb :profile
  end

  get '/add_channel' do
    if user.nil?
      return redirect '/login', 303
    end

    @channels, = get_channel_list_info
    erb :add_channel
  end

  post '/add_channel' do
    if user.nil?
      return redirect '/login', 303
    end

    name = params[:name]
    description = params[:description]
    if name.nil? || description.nil?
      return 400
    end
    statement = db.prepare('INSERT INTO channel (name, description, updated_at, created_at) VALUES (?, ?, NOW(), NOW())')
    statement.execute(name, description)
    channel_id = db.last_id
    statement.close

    redis.hset(redis_key_total_messages, channel_id, 0)
    redis.publish(AwesomeFetch::STREAM_KEY, '')
    redirect "/channel/#{channel_id}", 303
  end

  post '/profile' do
    if user.nil?
      return redirect '/login', 303
    end

    if user.nil?
      return 403
    end

    display_name = params[:display_name]
    avatar_name = nil
    avatar_data = nil

    file = params[:avatar_icon]
    unless file.nil?
      filename = file[:filename]
      if !filename.nil? && !filename.empty?
        ext = filename.include?('.') ? File.extname(filename) : ''
        unless ['.jpg', '.jpeg', '.png', '.gif'].include?(ext)
          return 400
        end

        if settings.avatar_max_size < file[:tempfile].size
          return 400
        end

        data = file[:tempfile].read
        digest = Digest::SHA1.hexdigest(data)

        avatar_name = digest + ext
        avatar_data = data
        path = File.join(icons_dir, avatar_name)
        File.write(path, avatar_data) unless File.exists?(path)
      end
    end

    keys = []
    values = []

    if !avatar_name.nil? && !avatar_data.nil?
      # statement = db.prepare('INSERT INTO image (name, data) VALUES (?, ?)')
      # statement.execute(avatar_name, avatar_data)
      # statement.close
      keys << 'avatar_icon = ?'
      values << avatar_name
    end

    if !display_name.nil? || !display_name.empty?
      keys << 'display_name = ?'
      values << display_name
    end

    if keys.size > 0
      statement = db.prepare("UPDATE user SET #{keys.join(', ')} WHERE id = ?")
      statement.execute(*values, user['id'])
      statement.close
    end

    redirect '/', 303
  end

  get '/icons/:file_name' do
    file_name = params[:file_name]
    statement = db.prepare('SELECT * FROM image WHERE name = ?')
    row = statement.execute(file_name).first
    statement.close
    ext = file_name.include?('.') ? File.extname(file_name) : ''
    mime = ext2mime(ext)
    if !row.nil? && !mime.empty?
      content_type mime
      return row['data']
    end
    404
  end

  post '/dump/icons' do
    rows = db.query('SELECT `name`, `data` FROM `image`')

    rows.each do |row|
      File.binwrite(File.join(icons_dir, row['name']), row['data'])
    end

    return "OK"
  end

  private

  def icons_dir
    @icons_dir ||= "#{ENV['HOME']}/public/icons"
  end

  def redis
    Thread.current[:isubata_redis] ||= Redis.new(url: ENV.fetch('ISUBATA_REDIS_URL', 'redis://localhost:6379/0'))
  end

  def redis_key_lastreads(user_id)
    "isubata:lastreads:#{user_id}"
  end
  def redis_key_total_messages
    "isubata:total_messages"
  end

  def redis_fetch(key, ttl: nil)
    e =  redis.get(key)
    if e
      MessagePack.unpack e
    else
      yield.tap do |r|
        if ttl
          redis.psetex(key, ms, r.to_msgpack)
        else
          redis.set(key, r.to_msgpack)
        end
      end
    end
  end

  #def redis_key_unreads(user_id, channel_id)
  #  "isubata:unreads:#{user_id}:#{channel_id}"
  #end

  def db
    Thread.current[:isubata_db] ||= Mysql2::Client.new(
      host: ENV.fetch('ISUBATA_DB_HOST') { 'localhost' },
      port: ENV.fetch('ISUBATA_DB_PORT') { '3306' },
      username: ENV.fetch('ISUBATA_DB_USER') { 'root' },
      password: ENV.fetch('ISUBATA_DB_PASSWORD') { '' },
      database: 'isubata',
      encoding: 'utf8mb4',
      reconnect: true,
      init_command: %q!SET SESSION sql_mode='TRADITIONAL,NO_AUTO_VALUE_ON_ZERO,ONLY_FULL_GROUP_BY'!
    )
  end

  def db_get_user(user_id)
    statement = db.prepare('SELECT * FROM user WHERE id = ?')
    user = statement.execute(user_id).first
    statement.close
    user
  end

  def db_add_message(channel_id, user_id, content)
    statement = db.prepare('INSERT INTO message (channel_id, user_id, content, created_at) VALUES (?, ?, ?, NOW())')
    messages = statement.execute(channel_id, user_id, content)
    statement.close
    redis.hincrby(redis_key_total_messages, channel_id, 1)
    redis.publish(AwesomeFetch::STREAM_KEY, '')
    session[:bakusoku] = true
    messages
  end

  def random_string(n)
    Array.new(20).map { (('a'..'z').to_a + ('A'..'Z').to_a + ('0'..'9').to_a).sample }.join
  end

  def register(user, password)
    salt = random_string(20)
    pass_digest = Digest::SHA1.hexdigest(salt + password)
    statement = db.prepare('INSERT INTO user (name, salt, password, display_name, avatar_icon, created_at) VALUES (?, ?, ?, ?, ?, NOW())')
    statement.execute(user, salt, pass_digest, user, 'default.png')
    row = db.query('SELECT LAST_INSERT_ID() AS last_insert_id').first
    statement.close
    session[:bakusoku] = true
    row['last_insert_id']
  end

  def get_channel_list_info(focus_channel_id = nil)
    @channel_list ||= db.query('SELECT id,name FROM channel ORDER BY id').to_a
    if focus_channel_id
      statement = db.prepare('SELECT description FROM channel WHERE id = ? LIMIT 1')
      description = statement.execute(focus_channel_id.to_i).first['description']
      statement.close
    end

    [@channel_list , description]
  end

  def ext2mime(ext)
    if ['.jpg', '.jpeg'].include?(ext)
      return 'image/jpeg'
    end
    if ext == '.png'
      return 'image/png'
    end
    if ext == '.gif'
      return 'image/gif'
    end
    ''
  end

  def get_users(ids)
    return {} if ids.empty?

    rows = db.query("SELECT id, name, display_name, avatar_icon FROM user WHERE id IN (#{ids.join(',')})")

    dict = {}
    rows.each do |row|
      dict[row['id']] = row.select { |k, v| %w[name display_name avatar_icon].include?(k) }
    end

    dict
  end
end
