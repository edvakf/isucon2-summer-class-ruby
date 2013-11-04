require 'sinatra/base'
require 'slim'
require 'json'
require 'mysql2'
require 'dalli'

class Isucon2App < Sinatra::Base
  $stdout.sync = true
  set :slim, :pretty => true, :layout => true

  @@artists = [
    {"id" => 1, "name" => 'NHN48'},
    {"id" => 2, "name" => 'はだいろクローバーZ'},
  ]

  @@artists_h = {
    1 => {"id" => 1, "name" => 'NHN48'},
    2 => {"id" => 2, "name" => 'はだいろクローバーZ'},
  }

  helpers do
    def connection
      config = JSON.parse(IO.read(File.dirname(__FILE__) + "/../config/common.#{ ENV['ISUCON_ENV'] || 'local' }.json"))['database']
      Mysql2::Client.new(
        :host => config['host'],
        :port => config['port'],
        :username => config['username'],
        :password => config['password'],
        :database => config['dbname'],
        :reconnect => true,
      )
    end

    def recent_sold
      mysql = connection
      query = mysql.query(
        'SELECT stock.seat_id, variation.name AS v_name, ticket.name AS t_name, ticket.artist_id AS a_id FROM stock
           JOIN variation ON stock.variation_id = variation.id
           JOIN ticket ON variation.ticket_id = ticket.id
         WHERE order_id IS NOT NULL
         ORDER BY order_id DESC LIMIT 10',
      )

      res = []
      query.each {|item|
        item['a_name'] = @@artists_h[item['a_id'].to_i]['name']
        res << item
      }
      return res
    end
  end

  # main

  get '/' do
    slim :index, :locals => {
      :artists => @@artists,
    }
  end

  get '/artist/:artistid' do
    artist = @@artists_h[params[:artistid].to_i]
    mysql = connection
    tickets = mysql.query(
      "SELECT id, name FROM ticket WHERE artist_id = #{ mysql.escape(artist['id'].to_s) } ORDER BY id",
    )
    tickets.each do |ticket|
      ticket["count"] = mysql.query(
        "SELECT COUNT(*) AS cnt FROM variation
         INNER JOIN stock ON stock.variation_id = variation.id
         WHERE variation.ticket_id = #{ mysql.escape(ticket['id'].to_s) } AND stock.order_id IS NULL",
      ).first["cnt"]
    end
    slim :artist, :locals => {
      :artist  => artist,
      :tickets => tickets,
    }
  end

  get '/ticket/:ticketid' do
    mysql = connection
    ticket = mysql.query(
      "SELECT t.* FROM ticket t
       WHERE t.id = #{ mysql.escape(params[:ticketid]) } LIMIT 1",
    ).first
    ticket['artist_name'] = @@artists_h[ticket['artist_id'].to_i]['name']
    variations = mysql.query(
      "SELECT id, name FROM variation WHERE ticket_id = #{ mysql.escape(ticket['id'].to_s) } ORDER BY id",
    )
    variations.each do |variation|
      variation["count"] = mysql.query(
        "SELECT COUNT(*) AS cnt FROM stock
         WHERE variation_id = #{ mysql.escape(variation['id'].to_s) } AND order_id IS NULL",
      ).first["cnt"]
      variation["stock"] = {}
      mysql.query(
        "SELECT seat_id, order_id FROM stock
         WHERE variation_id = #{ mysql.escape(variation['id'].to_s) }",
      ).each do |stock|
        variation["stock"][stock["seat_id"]] = stock["order_id"]
      end
    end
    slim :ticket, :locals => {
      :ticket     => ticket,
      :variations => variations,
    }
  end

  post '/buy' do
    mysql = connection
    mysql.query('BEGIN')
    mysql.query("INSERT INTO order_request (member_id) VALUES ('#{ mysql.escape(params[:member_id]) }')")
    order_id = mysql.last_id
    mysql.query(
      "UPDATE stock SET order_id = #{ mysql.escape(order_id.to_s) }
       WHERE variation_id = #{ mysql.escape(params[:variation_id]) } AND order_id IS NULL
       ORDER BY RAND() LIMIT 1",
    )
    if mysql.affected_rows > 0
      seat_id = mysql.query(
        "SELECT seat_id FROM stock WHERE order_id = #{ mysql.escape(order_id.to_s) } LIMIT 1",
      ).first['seat_id']
      mysql.query('COMMIT')
      slim :complete, :locals => { :seat_id => seat_id, :member_id => params[:member_id] }
    else
      mysql.query('ROLLBACK')
      slim :soldout
    end
  end

  # admin

  get '/admin' do
    slim :admin
  end

  get '/admin/order.csv' do
    mysql = connection
    body  = ''
    orders = mysql.query(
      'SELECT order_request.*, stock.seat_id, stock.variation_id, stock.updated_at
       FROM order_request JOIN stock ON order_request.id = stock.order_id
       ORDER BY order_request.id ASC',
    )
    orders.each do |order|
      order['updated_at'] = order['updated_at'].strftime('%Y-%m-%d %X')
      body += order.values_at('id', 'member_id', 'seat_id', 'variation_id', 'updated_at').join(',')
      body += "\n"
    end
    [200, { 'Content-Type' => 'text/csv' }, body]
  end

  post '/admin' do
    mysql = connection
    open(File.dirname(__FILE__) + '/../config/database/initial_data.sql') do |file|
      file.each do |line|
        next unless line.strip!.length > 0
        mysql.query(line)
      end
    end
    redirect '/admin', 302
  end

  run! if app_file == $0
end
