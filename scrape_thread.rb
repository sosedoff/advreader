require "bundler/setup"
require "faraday"
require "nokogiri"
require "sequel"

db = Sequel.sqlite("db.sqlite")

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

url = ARGV.shift
unless url
  puts "Please provide base URL to crawl"
  exit 1
end

page = 1

loop do
  thread_id = url.scan(/threads\/(.*)\//)[0][0]
  page_id = Digest::SHA1.hexdigest(url)
  page_file = "./pages/#{page_id}.html"

  # Fetch from live source or from cache
  if File.exists?(page_file)
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

  thread = db[:threads].where(id: thread_id).first
  unless thread
    puts "Creating a new thread: #{thread_id}"
    new_thread_id = db[:threads].insert(
      id: thread_id,
      author: posts.first[:meta][:author]
    )
    thread = db[:threads].where(id: thread_id).first
    puts "===> #{thread.inspect}"
  end

  # Save posts to database
  posts.each do |post|
    post_id = thread[:id] + "." + post[:meta][:post_number].to_s
    next if db[:posts].where(id: post_id).first

    puts post_id

    db[:posts].insert(
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