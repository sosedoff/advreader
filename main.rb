require "bundler/setup"
require "faraday"
require "nokogiri"
require "sinatra"
require "json"
require "sequel"

db = Sequel.sqlite("db.sqlite")

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
    where { number > start_number }.
    order("number asc").
    limit(10).
    to_a

  @posts.each_with_index do |post, idx|
    @posts[idx][:content] = post[:content].
      split("<br>").
      map { |chunk| "<p>" + chunk.strip + "</p>" }.
      join("\n")
  end

  if @posts.any?
    @next_id = @posts.last[:number]
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
