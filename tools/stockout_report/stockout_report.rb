#!/usr/bin/env ruby
# frozen_string_literal: true

# Stockout Risk Report
#
# Turns a diaper bank's spreadsheet export into a one-page HTML report:
# which items are likely to run out, how much to reorder, and how accurate
# the forecast would have been on the bank's own history.
#
# It reuses the exact forecasting and reorder math from the Replenishment
# Planner (app/services/replenishment/), so it needs plain Ruby only; no
# database, no Rails.
#
# Usage:
#   ruby tools/stockout_report/stockout_report.rb distributions.csv \
#     [--on-hand on_hand.csv] [--bank "Athens Area Diaper Bank"] \
#     [--lead-time 30] [--review 14] [--service-level 0.95] [--out report.html]
#
# distributions.csv can be either:
#   long format:  item,month,quantity          (one row per item per month)
#   wide format:  item,2025-01,2025-02,...     (one row per item)
# Months may be written 2025-03, 3/2025, Mar 2025, or a full date.
#
# on_hand.csv (optional): item,on_hand
# Without it, the report still gives forecasts and reorder points but can't
# say which items are at risk right now.

require "csv"
require "date"
require "erb"
require "optparse"

require_relative "../../app/services/replenishment/demand_forecaster"
require_relative "../../app/services/replenishment/reorder_policy"

module StockoutReport
  MONTH_NAMES = Date::ABBR_MONTHNAMES.compact.map(&:downcase)

  module_function

  def parse_month(raw)
    s = raw.to_s.strip
    return nil if s.empty?

    case s
    when /\A(\d{4})[-\/](\d{1,2})(?:[-\/]\d{1,2})?\z/ then Date.new($1.to_i, $2.to_i, 1)
    when /\A(\d{1,2})[-\/](\d{4})\z/ then Date.new($2.to_i, $1.to_i, 1)
    when /\A(\d{1,2})\/\d{1,2}\/(\d{2,4})\z/
      year = $2.to_i
      year += 2000 if year < 100
      Date.new(year, $1.to_i, 1)
    when /\A([A-Za-z]{3})[a-z]*[\s\-']+(\d{2,4})\z/
      month = MONTH_NAMES.index($1.downcase)
      return nil unless month

      year = $2.to_i
      year += 2000 if year < 100
      Date.new(year, month + 1, 1)
    end
  rescue Date::Error
    nil
  end

  def to_number(raw)
    raw.to_s.delete(",").strip.then { |s| s.empty? ? 0 : Float(s) }
  rescue ArgumentError
    0
  end

  # Returns [ { item => { month => qty } }, [warnings] ]
  def read_demand(path)
    rows = CSV.read(path, encoding: "bom|utf-8", headers: true, header_converters: ->(h) { h.to_s.strip })
    headers = rows.headers.compact
    item_col = headers.find { |h| h.match?(/item|product|name/i) } || headers.first
    demand = Hash.new { |h, k| h[k] = Hash.new(0.0) }
    warnings = []

    month_cols = headers.select { |h| parse_month(h) }
    if month_cols.size >= 2
      rows.each do |row|
        item = row[item_col].to_s.strip
        next if item.empty?

        month_cols.each { |col| demand[item][parse_month(col)] += to_number(row[col]) }
      end
    else
      month_col = headers.find { |h| h.match?(/month|date|period/i) }
      qty_col = headers.find { |h| h.match?(/qty|quantity|amount|distributed|total|units/i) }
      raise "Couldn't find month and quantity columns in #{path} (headers: #{headers.join(", ")})" unless month_col && qty_col

      rows.each_with_index do |row, i|
        item = row[item_col].to_s.strip
        month = parse_month(row[month_col])
        if item.empty? || month.nil?
          warnings << "Skipped row #{i + 2}: couldn't read item or month" unless item.empty? && row[month_col].to_s.strip.empty?
          next
        end
        demand[item][month] += to_number(row[qty_col])
      end
    end
    [demand, warnings]
  end

  def read_on_hand(path)
    return {} unless path

    rows = CSV.read(path, encoding: "bom|utf-8", headers: true, header_converters: ->(h) { h.to_s.strip })
    item_col = rows.headers.find { |h| h.to_s.match?(/item|product|name/i) } || rows.headers.first
    qty_col = rows.headers.find { |h| h.to_s.match?(/hand|stock|inventory|qty|quantity/i) } || rows.headers[1]
    rows.to_h { |r| [r[item_col].to_s.strip, to_number(r[qty_col]).to_i] }
  end

  # Fill gaps so every item has a value for every month in the window.
  def monthly_series(by_month, first, last)
    months = []
    m = first
    while m <= last
      months << m
      m = m.next_month
    end
    [months, months.map { |mo| by_month.fetch(mo, 0.0) }]
  end

  Row = Struct.new(:item, :months, :history, :forecast, :decision, :on_hand, keyword_init: true)

  def build(demand, on_hand, lead_time:, review:, service_level:, today:)
    all_months = demand.values.flat_map(&:keys)
    raise "No usable rows found" if all_months.empty?

    first = all_months.min
    last = all_months.max
    rows = demand.map do |item, by_month|
      months, history = monthly_series(by_month, first, last)
      forecast = Replenishment::DemandForecaster.new(history, horizon: 3).call
      stock = on_hand[item]
      decision = Replenishment::ReorderPolicy.new(
        forecast: forecast.forecast, sigma: forecast.sigma, on_hand: stock || 0,
        lead_time_days: lead_time, review_period_days: review,
        service_level: service_level, today: today
      ).call
      Row.new(item:, months:, history:, forecast:, decision:, on_hand: stock)
    end

    order = {critical: 0, reorder: 1, ok: 2, no_demand: 3}
    rows.sort_by { |r| [r.on_hand ? order[r.decision.status] : 4, -r.forecast.next_month, r.item] }
  end

  def overall_skill(rows)
    scored = rows.select { |r| r.forecast.mae && r.forecast.naive_mae&.positive? }
    return nil if scored.empty?

    1 - (scored.sum { |r| r.forecast.mae } / scored.sum { |r| r.forecast.naive_mae })
  end

  def sparkline(values, width: 120, height: 28)
    return "" if values.empty? || values.max.to_f.zero?

    max = values.max.to_f
    step = values.size > 1 ? width.to_f / (values.size - 1) : 0
    pts = values.each_with_index.map { |v, i| format("%.1f,%.1f", i * step, height - (v / max * (height - 2)) - 1) }
    %(<svg width="#{width}" height="#{height}" viewBox="0 0 #{width} #{height}" aria-hidden="true"><polyline fill="none" stroke="currentColor" stroke-width="1.5" points="#{pts.join(" ")}"/></svg>)
  end

  def fmt(n)
    n.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
  end

  STATUS = {
    critical: ["Order now", "crit", "Will likely run out before a new order can arrive"],
    reorder: ["Reorder", "warn", "At or below the reorder point"],
    ok: ["OK", "ok", "Above the reorder point"],
    no_demand: ["No demand", "muted", "No recent distributions"]
  }.freeze

  TEMPLATE = ERB.new(File.read(File.join(__dir__, "report.html.erb"), encoding: "UTF-8"), trim_mode: "-")

  def render(bank:, rows:, settings:, warnings:, today:)
    has_on_hand = rows.any?(&:on_hand)
    skill = overall_skill(rows)
    TEMPLATE.result(binding)
  end
end

if $PROGRAM_NAME == __FILE__
  opts = {lead_time: 30, review: 14, service_level: 0.95, bank: "Your diaper bank", out: "stockout_report.html"}
  OptionParser.new do |o|
    o.banner = "Usage: stockout_report.rb distributions.csv [options]"
    o.on("--on-hand FILE") { |v| opts[:on_hand] = v }
    o.on("--bank NAME") { |v| opts[:bank] = v }
    o.on("--lead-time DAYS", Integer) { |v| opts[:lead_time] = v }
    o.on("--review DAYS", Integer) { |v| opts[:review] = v }
    o.on("--service-level P", Float) { |v| opts[:service_level] = v }
    o.on("--out FILE") { |v| opts[:out] = v }
  end.parse!
  abort "Missing distributions CSV. Try --help." if ARGV.empty?

  today = Date.today
  demand, warnings = StockoutReport.read_demand(ARGV[0])
  on_hand = StockoutReport.read_on_hand(opts[:on_hand])
  missing = on_hand.keys - demand.keys
  warnings << "On-hand items with no distribution history: #{missing.join(", ")}" if missing.any?
  rows = StockoutReport.build(demand, on_hand, lead_time: opts[:lead_time], review: opts[:review],
    service_level: opts[:service_level], today: today)
  html = StockoutReport.render(bank: opts[:bank], rows: rows, settings: opts, warnings: warnings, today: today)
  File.write(opts[:out], html, encoding: "UTF-8")

  csv_path = opts[:out].sub(/\.html?\z/, "") + ".csv"
  CSV.open(csv_path, "w") do |csv|
    csv << %w[item status on_hand forecast_next_month reorder_point suggested_order days_of_supply model forecast_error_vs_naive]
    rows.each do |r|
      csv << [r.item, (r.on_hand ? r.decision.status : "unknown"), r.on_hand, r.forecast.next_month.round,
        r.decision.reorder_point, (r.on_hand ? r.decision.suggested_order : nil), (r.on_hand ? r.decision.days_of_supply : nil),
        r.forecast.model, r.forecast.skill&.round(3)]
    end
  end
  puts "Wrote #{opts[:out]} and #{csv_path} (#{rows.size} items)"
  warnings.each { |w| warn "warning: #{w}" }
end
