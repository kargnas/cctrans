#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Fetch App Store Connect review status + rejection details for a macOS app.
#
# WHY Apple-ID (spaceship) auth instead of an ASC API key:
#   The Resolution Center endpoints (rejection messages, reviewRejections) are
#   ONLY served to Apple-ID web sessions — never to a .p8 API key. Apple gates
#   them server-side. We therefore reuse the persisted fastlane spaceship cookie
#   (created by `fastlane spaceauth`) rather than the ASC API key, whose issuer
#   id is not even stored on this machine.
#
# Run via scripts/asc-review.zsh, which injects fastlane's bundled ruby + gems.
# Config comes from ENV (defaults target CCTrans); see SKILL.md.

require "spaceship"
require "json"

USER   = ENV.fetch("ASC_USER", "kars@kargn.as")
APP_ID = ENV.fetch("ASC_APP_ID", "6779669255") # CCTrans (ASC "Apple ID")

# Convert Apple's HTML message bodies into readable plain text. Apple wraps the
# rejection text in <br>/<h3>/<b>/<a> — we keep link URLs inline so the crash-log
# and documentation references survive the conversion.
def html_to_text(str)
  str.to_s
     .gsub(%r{<\s*br\s*/?>}i, "\n")
     .gsub(%r{</?h[1-6][^>]*>}i, "\n")
     .gsub(%r{<a\b[^>]*href="([^"]*)"[^>]*>(.*?)</a>}im) { "#{Regexp.last_match(2)} <#{Regexp.last_match(1)}>" }
     .gsub(/<[^>]+>/, "")
     .gsub("&amp;", "&").gsub("&lt;", "<").gsub("&gt;", ">")
     .gsub("&nbsp;", " ").gsub("&#39;", "'").gsub("&quot;", '"')
     .split("\n").map(&:rstrip).join("\n").gsub(/\n{3,}/, "\n\n").strip
end

begin
  Spaceship::ConnectAPI.login(USER, use_portal: false, use_tunes: true)
rescue StandardError => e
  warn "LOGIN_FAILED: #{e.class}: #{e.message}"
  warn "Hint: the persisted Apple-ID session expired. Re-auth once with:"
  warn "  fastlane spaceauth -u #{USER}"
  warn "If it asks to pick a team, set ASC_TEAM_ID (the wrapper passes it on)."
  exit 2
end

app = Spaceship::ConnectAPI::App.get(app_id: APP_ID)
puts "App:  #{app.name} (#{app.bundle_id})  sku=#{app.sku}  id=#{APP_ID}"
puts "Web:  https://appstoreconnect.apple.com/apps/#{APP_ID}/distribution"
puts

puts "== App Store versions (newest first) =="
app.get_app_store_versions.sort_by { |v| v.created_date.to_s }.reverse.first(5).each do |v|
  puts "  #{v.platform}  v#{v.version_string}  state=#{v.app_store_state}  created=#{v.created_date}"
end
puts

subs = app.get_review_submissions
puts "== Review submissions (newest first) =="
subs.sort_by { |s| s.submitted_date.to_s }.reverse.each do |s|
  puts "  #{s.platform}  state=#{s.state}  submitted=#{s.submitted_date}  id=#{s.id}"
end
puts

# Low-level tunes client: reviewRejections (guideline codes) has no spaceship model.
trc = Spaceship::ConnectAPI.client.instance_variable_get(:@tunes_request_client)

def reason_codes(trc, thread_id)
  resp = trc.get("v1/reviewRejections?filter[resolutionCenterMessage.resolutionCenterThread]=#{thread_id}")
  Array(resp.body["data"]).flat_map do |r|
    Array(r.dig("attributes", "reasons")).map { |x| "#{x['reasonCode']} #{x['reasonDescription']}" }
  end.uniq
rescue StandardError
  [] # non-fatal: messages already carry the human-readable guideline text
end

puts "== Resolution Center (rejection threads & messages) =="
found = false
subs.each do |s|
  s.fetch_resolution_center_threads.each do |t|
    found = true
    codes = reason_codes(trc, t.id)
    puts "\n  THREAD #{t.thread_type}  submission=#{s.id}"
    puts "  Guideline: #{codes.join(' | ')}" unless codes.empty?

    resp = Spaceship::ConnectAPI.get_resolution_center_messages(
      thread_id: t.id, includes: "resolutionCenterMessageAttachments"
    )
    body     = resp.body
    included = Array(body["included"])

    Array(body["data"]).sort_by { |m| m.dig("attributes", "createdDate").to_s }.each do |m|
      puts "\n  --- message #{m.dig('attributes', 'createdDate')} ---"
      html_to_text(m.dig("attributes", "messageBody")).each_line { |ln| puts "  #{ln.rstrip}" }

      refs = Array(m.dig("relationships", "resolutionCenterMessageAttachments", "data"))
      if refs.empty?
        # Apple's own crash-log / screenshot attachments are NOT exposed through
        # this relationship (it only carries developer-uploaded files). When the
        # body references an attachment, point at the web UI to download it.
        if m.dig("attributes", "messageBody").to_s.match?(/attach(ed|ment)/i)
          puts "  [Apple attached a file (crash log / screenshot). It is NOT served via API."
          puts "   Download it from the Resolution Center web UI:"
          puts "   https://appstoreconnect.apple.com/apps/#{APP_ID}/distribution ]"
        end
      else
        refs.each do |ref|
          obj   = included.find { |x| x["type"] == ref["type"] && x["id"] == ref["id"] }
          attrs = obj ? obj["attributes"] : {}
          puts "  [attachment id=#{ref['id']} #{JSON.generate(attrs)}]"
        end
      end
    end
  end
end
puts "  (no resolution-center threads — app not rejected / no review messages)" unless found
puts

puts "== TestFlight builds (newest first) =="
app.get_builds(includes: "preReleaseVersion,buildBetaDetail").first(6).each do |b|
  bbd = b.build_beta_detail
  puts "  build #{b.version}  processing=#{b.processing_state}  beta_ext=#{bbd&.external_build_state}  expired=#{b.expired}"
end
