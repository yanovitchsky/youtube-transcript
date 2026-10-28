# frozen_string_literal: true

require "sinatra"
require "net/http"
require "uri"
require "cgi"
require "json"

class TranscriptError < StandardError; end

set :bind, "0.0.0.0"
set :port, 3334

USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

def extract_video_id(url)
  raw = url.to_s.strip
  return raw if raw.match?(/\A[A-Za-z0-9_-]{11}\z/)

  uri = URI.parse(raw)
  host = uri.host.to_s.sub(/\Awww\./, "")
  candidate =
    if host == "youtu.be"
      uri.path.to_s.delete_prefix("/")
    elsif uri.path.to_s.start_with?("/shorts/", "/embed/")
      uri.path.split("/")[2]
    else
      CGI.parse(uri.query.to_s)["v"]&.first
    end
  candidate.to_s[/\A[A-Za-z0-9_-]{11}/]
rescue URI::InvalidURIError
  nil
end

def http_get(url, limit = 3)
  raise TranscriptError, "Could not read video page" if limit <= 0

  uri = URI(url)
  response = Net::HTTP.start(uri.host, uri.port || 443, use_ssl: uri.scheme == "https") do |http|
    req = Net::HTTP::Get.new(uri)
    req["User-Agent"] = USER_AGENT
    req["Accept-Language"] = "en-US,en;q=0.9"
    req["Cookie"] = "CONSENT=YES+cb"
    http.request(req)
  end

  case response
  when Net::HTTPRedirection
    location = response["location"]
    raise TranscriptError, "Could not read video page" if location.nil? || location.empty?

    next_url = URI.join(url, location).to_s
    http_get(next_url, limit - 1)
  else
    response
  end
end

def extract_json_object(html, marker)
  idx = html.index(marker)
  return nil unless idx

  start = html.index("{", idx + marker.length)
  return nil unless start

  depth = 0
  in_string = false
  escape = false
  i = start
  while i < html.length
    ch = html[i]
    if in_string
      if escape
        escape = false
      elsif ch == "\\"
        escape = true
      elsif ch == '"'
        in_string = false
      end
    elsif ch == '"'
      in_string = true
    elsif ch == "{"
      depth += 1
    elsif ch == "}"
      depth -= 1
      return html[start..i] if depth.zero?
    end
    i += 1
  end
  nil
end

def player_response_android(video_id)
  uri = URI("https://www.youtube.com/youtubei/v1/player?prettyPrint=false")
  payload = {
    context: { client: { clientName: "ANDROID", clientVersion: "20.10.38", hl: "en" } },
    videoId: video_id
  }.to_json
  response = Net::HTTP.start(uri.host, 443, use_ssl: true) do |http|
    req = Net::HTTP::Post.new(uri)
    req["User-Agent"] = "com.google.android.youtube/20.10.38 (Linux; U; Android 14)"
    req["Content-Type"] = "application/json"
    req.body = payload
    http.request(req)
  end
  raise TranscriptError, "Could not read video page" unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body)
end

def caption_segments(xml)
  xml.scan(/<(?:text|p)(?:\s[^>]*)?>(.*?)<\/(?:text|p)>/m).map do |(content)|
    CGI.unescapeHTML(CGI.unescapeHTML(content)).gsub(/<[^>]+>/, "").strip
  end.reject(&:empty?)
end

def fetch_transcript(video_id)
  page = http_get("https://www.youtube.com/watch?v=#{video_id}")
  body = page.body.to_s
  json = extract_json_object(body, "ytInitialPlayerResponse = ") ||
         extract_json_object(body, "ytInitialPlayerResponse=")
  raise TranscriptError, "Could not read video page" unless json

  pr = JSON.parse(json)
  title = pr.dig("videoDetails", "title").to_s
  title = "Transcript" if title.empty?

  tracks = pr.dig("captions", "playerCaptionsTracklistRenderer", "captionTracks")
  if tracks.nil? || tracks.empty?
    pr = player_response_android(video_id)
    title = pr.dig("videoDetails", "title").to_s if title == "Transcript"
    title = "Transcript" if title.to_s.empty?
    tracks = pr.dig("captions", "playerCaptionsTracklistRenderer", "captionTracks")
  end
  raise TranscriptError, "No captions available for this video" if tracks.nil? || tracks.empty?

  track = tracks.find { |t| t["languageCode"].to_s.start_with?("en") } || tracks.first
  base_url = track["baseUrl"]
  raise TranscriptError, "No captions available for this video" if base_url.nil? || base_url.empty?

  xml = http_get(base_url).body.to_s
  segments = caption_segments(xml)
  if segments.empty?
    pr = player_response_android(video_id)
    android_title = pr.dig("videoDetails", "title").to_s
    title = android_title unless android_title.empty?
    tracks = pr.dig("captions", "playerCaptionsTracklistRenderer", "captionTracks")
    raise TranscriptError, "No captions available for this video" if tracks.nil? || tracks.empty?

    track = tracks.find { |t| t["languageCode"].to_s.start_with?("en") } || tracks.first
    xml = http_get(track["baseUrl"]).body.to_s
    segments = caption_segments(xml)
  end

  raise TranscriptError, "Transcript could not be parsed" if segments.empty?

  { title: title, segments: segments }
end

def to_markdown(title, segments)
  paragraphs = []
  buffer = +""
  segments.each do |segment|
    buffer << " " unless buffer.empty?
    buffer << segment
    if buffer.length > 350
      paragraphs << buffer.strip
      buffer = +""
    end
  end
  paragraphs << buffer.strip unless buffer.empty?

  ["# #{title}", "", paragraphs.join("\n\n")].join("\n")
end

def transcript_markdown(url)
  id = extract_video_id(url)
  raise TranscriptError, "Invalid YouTube URL" unless id

  data = fetch_transcript(id)
  to_markdown(data[:title], data[:segments])
end

get "/" do
  erb :index, locals: { markdown: nil, error: nil, url: "" }
end

post "/transcript" do
  url = params[:url].to_s
  begin
    md = transcript_markdown(url)
    erb :index, locals: { markdown: md, error: nil, url: url }
  rescue TranscriptError => e
    erb :index, locals: { markdown: nil, error: e.message, url: url }
  rescue StandardError => e
    erb :index, locals: { markdown: nil, error: "Unexpected error: #{e.message}", url: url }
  end
end

get "/transcript.md" do
  content_type "text/markdown"
  begin
    transcript_markdown(params[:url])
  rescue TranscriptError => e
    "# Error\n\n#{e.message}\n"
  rescue StandardError => e
    "# Error\n\nUnexpected error: #{e.message}\n"
  end
end

template :index do
  <<~HTML
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>YouTube Transcript</title>
      <link rel="preconnect" href="https://fonts.googleapis.com">
      <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
      <link href="https://fonts.googleapis.com/css2?family=Bodoni+Moda:opsz,wght@6..96,500;6..96,700&family=IBM+Plex+Mono:wght@400;500&family=Schibsted+Grotesk:wght@400;500;600&display=swap" rel="stylesheet">
      <style>
        :root {
          --ink: #1a1410;
          --paper: #f3eadc;
          --paper-edge: #e4d5c0;
          --cream: #f7f1e7;
          --muted: #8a7b6c;
          --line: rgba(26, 20, 16, 0.12);
          --ember: #d84a2f;
          --ember-deep: #a8321c;
          --night: #14110e;
          --night-2: #221c17;
        }
        * { box-sizing: border-box; }
        html, body { margin: 0; min-height: 100%; }
        body {
          color: var(--cream);
          font-family: "Schibsted Grotesk", sans-serif;
          background:
            radial-gradient(900px 480px at 12% -10%, rgba(216, 74, 47, 0.28), transparent 60%),
            radial-gradient(700px 500px at 100% 0%, rgba(243, 234, 220, 0.08), transparent 55%),
            linear-gradient(165deg, var(--night-2), var(--night) 42%, #0d0b09);
          min-height: 100vh;
        }
        body::before {
          content: "";
          pointer-events: none;
          position: fixed;
          inset: 0;
          opacity: 0.18;
          background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='140' height='140'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='.85' numOctaves='2' stitchTiles='stitch'/></filter><rect width='100%' height='100%' filter='url(%23n)' opacity='.55'/></svg>");
          mix-blend-mode: overlay;
        }
        .wrap {
          position: relative;
          max-width: 920px;
          margin: 0 auto;
          padding: 3.2rem 1.4rem 4rem;
        }
        .kicker {
          display: flex;
          align-items: center;
          gap: 0.75rem;
          letter-spacing: 0.28em;
          text-transform: uppercase;
          font-size: 0.68rem;
          color: var(--muted);
          margin: 0 0 0.8rem;
        }
        .kicker i {
          width: 2.2rem;
          height: 1px;
          background: var(--ember);
          display: inline-block;
        }
        h1 {
          font-family: "Bodoni Moda", serif;
          font-weight: 500;
          font-size: clamp(3.4rem, 8vw, 6.4rem);
          line-height: 0.88;
          letter-spacing: -0.03em;
          margin: 0 0 0.6rem;
        }
        h1 em {
          font-style: italic;
          color: #f0c7b4;
        }
        .lede {
          max-width: 34rem;
          color: #cbbbaa;
          font-size: 1.05rem;
          line-height: 1.45;
          margin: 0 0 1.8rem;
        }
        form {
          display: grid;
          grid-template-columns: 1fr auto;
          gap: 0.55rem;
          padding: 0.45rem;
          background: rgba(243, 234, 220, 0.06);
          border: 1px solid rgba(243, 234, 220, 0.14);
          border-radius: 999px;
          backdrop-filter: blur(8px);
        }
        input[type=url], input[type=text] {
          border: 0;
          background: transparent;
          color: var(--cream);
          font: 500 1rem "Schibsted Grotesk", sans-serif;
          padding: 0.85rem 1.1rem;
          outline: none;
          min-width: 0;
        }
        input::placeholder { color: #8d7d6e; }
        button[type=submit] {
          border: 0;
          cursor: pointer;
          border-radius: 999px;
          padding: 0.85rem 1.35rem;
          background: var(--ember);
          color: #fff8f3;
          font: 600 0.92rem "Schibsted Grotesk", sans-serif;
          letter-spacing: 0.02em;
          transition: transform 0.15s ease, background 0.15s ease;
        }
        button[type=submit]:hover { background: var(--ember-deep); transform: translateY(-1px); }
        button[type=submit]:disabled { opacity: 0.7; cursor: progress; }
        .error {
          margin: 1rem 0 0;
          padding: 0.85rem 1rem;
          border-left: 3px solid var(--ember);
          background: rgba(216, 74, 47, 0.12);
          color: #ffd2c6;
        }
        .sheet {
          margin-top: 2rem;
          background: var(--paper);
          color: var(--ink);
          border-radius: 2px 14px 14px 2px;
          box-shadow:
            0 30px 70px rgba(0, 0, 0, 0.35),
            inset 6px 0 0 var(--ember);
          transform: rotate(-0.25deg);
          animation: rise 0.55s ease both;
        }
        @keyframes rise {
          from { opacity: 0; transform: translateY(14px) rotate(-0.8deg); }
          to { opacity: 1; transform: translateY(0) rotate(-0.25deg); }
        }
        .sheet-bar {
          display: flex;
          justify-content: space-between;
          align-items: center;
          gap: 1rem;
          padding: 0.85rem 1.1rem 0.7rem 1.35rem;
          border-bottom: 1px solid var(--paper-edge);
          font-size: 0.78rem;
          letter-spacing: 0.14em;
          text-transform: uppercase;
          color: #7a6a5b;
        }
        .actions { display: flex; gap: 0.4rem; }
        .actions button, .actions a {
          appearance: none;
          text-decoration: none;
          border: 1px solid #d9cbb8;
          background: transparent;
          color: var(--ink);
          font: 500 0.75rem "Schibsted Grotesk", sans-serif;
          letter-spacing: 0.06em;
          text-transform: uppercase;
          padding: 0.4rem 0.7rem;
          border-radius: 999px;
          cursor: pointer;
        }
        .actions button:hover, .actions a:hover { background: #efe4d4; }
        textarea {
          display: block;
          width: 100%;
          min-height: 28rem;
          border: 0;
          resize: vertical;
          background: transparent;
          color: var(--ink);
          padding: 1.15rem 1.35rem 1.6rem;
          font: 400 0.92rem/1.65 "IBM Plex Mono", ui-monospace, monospace;
          outline: none;
        }
        .empty {
          margin-top: 2.4rem;
          display: grid;
          grid-template-columns: auto 1fr;
          gap: 1rem;
          align-items: start;
          color: #b5a494;
          max-width: 36rem;
        }
        .mark {
          width: 2.4rem;
          height: 2.4rem;
          border-radius: 50%;
          border: 1px solid rgba(243, 234, 220, 0.25);
          display: grid;
          place-items: center;
        }
        .mark span {
          width: 0;
          height: 0;
          border-left: 9px solid var(--ember);
          border-top: 6px solid transparent;
          border-bottom: 6px solid transparent;
          margin-left: 2px;
        }
        @media (max-width: 640px) {
          form { border-radius: 1.2rem; grid-template-columns: 1fr; }
          h1 { font-size: 3.2rem; }
          .sheet { transform: none; }
        }
      </style>
    </head>
    <body>
      <main class="wrap">
        <p class="kicker"><i></i> Caption desk</p>
        <h1>Pull the<br><em>script.</em></h1>
        <p class="lede">Paste a YouTube link. English captions come back as markdown you can copy or download.</p>
        <form method="post" action="/transcript" id="pull">
          <input type="text" name="url" value="<%= Rack::Utils.escape_html(url) %>" placeholder="https://www.youtube.com/watch?v=…" required autocomplete="off" spellcheck="false">
          <button type="submit" id="go">Get transcript</button>
        </form>
        <% if error %>
          <p class="error"><%= Rack::Utils.escape_html(error) %></p>
        <% end %>
        <% if markdown %>
          <section class="sheet">
            <div class="sheet-bar">
              <span><%= markdown.lines.first.to_s.delete_prefix("# ").strip.then { |t| Rack::Utils.escape_html(t.empty? ? "Transcript" : t) } %></span>
              <div class="actions">
                <button type="button" id="copy">Copy</button>
                <a href="/transcript.md?url=<%= Rack::Utils.escape(url) %>">Download</a>
              </div>
            </div>
            <textarea id="md" readonly><%= markdown %></textarea>
          </section>
        <% elsif !error %>
          <div class="empty">
            <div class="mark" aria-hidden="true"><span></span></div>
            <p>A watch URL, a youtu.be link, or a bare 11-character id. The page stays here; the script lands on the paper below.</p>
          </div>
        <% end %>
      </main>
      <script>
        const form = document.getElementById("pull");
        const go = document.getElementById("go");
        form.addEventListener("submit", () => {
          go.disabled = true;
          go.textContent = "Pulling…";
        });
        const copy = document.getElementById("copy");
        if (copy) {
          copy.addEventListener("click", async () => {
            const text = document.getElementById("md").value;
            await navigator.clipboard.writeText(text);
            copy.textContent = "Copied";
            setTimeout(() => { copy.textContent = "Copy"; }, 1400);
          });
        }
      </script>
    </body>
    </html>
  HTML
end
