require "bundler/setup"
require "faraday"
require "nokogiri"
require "sinatra"
require "json"
require "sequel"

db = Sequel.sqlite("db.sqlite")
$db = db

db.run <<~SQL
  CREATE TABLE IF NOT EXISTS threads (
    id     TEXT PRIMARY KEY,
    author TEXT NOT NULL
  );
SQL

db.run <<~SQL
  CREATE TABLE IF NOT EXISTS posts (
    id           TEXT PRIMARY KEY,
    thread_id    TEXT NOT NULL,
    number       INTEGER NOT NULL,
    author       TEXT NOT NULL,
    timestamp    TEXT NOT NULL,
    content      TEXT NOT NULL,
    images_count INTEGER DEFAULT 0
  );
SQL

def cleanup_content(input)
  parts = input.
    split("<br>").
    map { |chunk| "<p>" + chunk.strip + "</p>" }

  result = []
  last_idx = 0

  parts.each do |part|
    if part.gsub(/<img [^>]+>/, "").gsub(/\s/, "").strip.length == 0
      result[last_idx] += part
    else
      result << part
      last_idx += 1
    end
  end

  result.join("\n")
end

def scrape_thread(url)
  page = 1

  loop do
    thread_id = url.scan(/threads\/(.*)\//)[0][0]
    page_id = Digest::SHA1.hexdigest(url)
    page_file = "./pages/#{page_id}.html"

    # Fetch from live source or from cache
    if File.exist?(page_file)
      puts "Loading from cache: #{page_file}"
      doc = Nokogiri::HTML(File.read(page_file))
    else
      puts "Fetching url: #{url}"
      resp = Faraday.get(url)
      if resp.success?
        File.write(page_file, resp.body)
      end
      doc = Nokogiri::HTML(resp.body)
    end
    
    base_url = doc.css("base").first.attr("href")

    posts = doc.css("li.message").map do |el|
      meta      = el.css(".messageMeta").first
      user_info = el.css(".messageUserInfo").first
      message   = el.css(".messageInfo").first

      images = {}
      message.css(".messageContent img").each do |img|
        next unless img["src"].start_with?("data/attachments")
        images[img["src"].to_s] = base_url + img["src"].to_s
      end

      content = message.css(".messageContent").to_s
      content.gsub!(/(<br>\s+){2,}/, "<br>")
      #content = content.split("<br>").map { |item| "<div class='section'>#{item}</div>" }.join("\n")

      # Process images
      images.each_pair { |orig, src| content.gsub!(orig, src) }

      {
        meta: {
          post_number:  meta.css(".publicControls").first.content.strip[1..-1].to_i,
          author:       meta.css("a.author").first.content,
          datetime:     meta.css(".DateTime").to_s,
          images_count: message.css(".messageContent .bbCodeImage").size
        },
        user: {
          name: user_info.css("a.username").first.content,
          avatar_url: base_url + user_info.css("a.avatar > img").attr("src").value,
        },
        message: {
          content: content
        }
      }
    end

    puts "Found #{posts.size} posts on this page"
    puts "Thread ID: #{thread_id}"

    thread = $db[:threads].where(id: thread_id).first
    unless thread
      puts "Creating a new thread: #{thread_id}"
      new_thread_id = $db[:threads].insert(
        id: thread_id,
        author: posts.first[:meta][:author]
      )
      thread = $db[:threads].where(id: thread_id).first
      puts "===> #{thread.inspect}"
    end

    # Save posts to database
    posts.each do |post|
      post_id = thread[:id] + "." + post[:meta][:post_number].to_s
      next if $db[:posts].where(id: post_id).first

      puts post_id

      $db[:posts].insert(
        id:           post_id,
        thread_id:    thread[:id],
        number:       post[:meta][:post_number],
        author:       post[:meta][:author],
        timestamp:    post[:meta][:datetime],
        content:      post[:message][:content],
        images_count: post[:meta][:images_count],
      )
    end

    # Determine the next page
    rels = doc.css("link").map { |item| [item["rel"], item["href"]] }.to_h
    unless rels["next"]
      puts "No more pages to process, stopping."
      break
    end

    # Start scraping the next page
    url = base_url + rels["next"]
  end
end

get "/" do
  @threads = db[:threads]
  erb :threads
end

get "/:author/:thread_id" do
  start_number = params.fetch(:after, 0).to_i
  thread_number = params[:thread_id].split(".").last

  @thread = db[:threads].
    where(Sequel.like(:id, "%#{thread_number}%")).
    first

  scope = db[:posts].
    where(thread_id: @thread[:id]).
    where(author: @thread[:author]).
    where { images_count > 0 }

  @posts = scope.dup.
    where { number >= start_number }.
    order("number asc").
    limit(10).
    to_a.
    map { |post| post[:content] = cleanup_content(post[:content]); post }

  @post = @posts.shift

  if @posts.any?
    @next_id = @posts.shift[:number]
  end

  erb :thread
end

get "/read" do
  resp = Faraday.get(params["url"])
  doc = Nokogiri::HTML(resp.body)
  base_url = doc.css("base").first.attr("href")

  @posts = doc.css("li.message").map do |el|
    meta = el.css(".messageMeta").first
    user_info = el.css(".messageUserInfo").first
    message = el.css(".messageInfo").first

    images = {}
    message.css(".messageContent img").each do |img|
      next unless img["src"].start_with?("data/attachments")
      images[img["src"].to_s] = base_url + img["src"].to_s
    end

    content = message.css(".messageContent").to_s
    content.gsub!(/(<br>\s+){2,}/, "<br>")
    #content = content.split("<br>").map { |item| "<div class='section'>#{item}</div>" }.join("\n")

    # Process images
    images.each_pair { |orig, src| content.gsub!(orig, src) }

    {
      meta: {
        post_number:  meta.css(".publicControls").first.content.strip[1..-1].to_i,
        author:       meta.css("a.author").first.content,
        datetime:     meta.css(".DateTime").to_s,
        images_count: message.css(".messageContent .bbCodeImage").size
      },
      user: {
        name: user_info.css("a.username").first.content,
        avatar_url: base_url + user_info.css("a.avatar > img").attr("src").value,
      },
      message: {
        content: content
      }
    }
  end

  @posts.reject! do |post|
    case
    #when post[:meta][:author] != "ExodusRider" then true
    when post[:meta][:images_count] == 0 then true
    end
  end

  rels = doc.css("link").map { |item| [item["rel"], item["href"]] }.to_h
  if rels["next"]
    @next_page_url = base_url + rels["next"]
  end

  erb :index
end

post "/scrape" do
  scrape_thread(params[:url])
  redirect "/"
end
