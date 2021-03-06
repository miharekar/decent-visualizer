# frozen_string_literal: true

class ShotChart
  extend Memoist

  DATA_LABELS_TO_IGNORE = %w[espresso_resistance espresso_resistance_weight espresso_state_change].freeze
  MAX_RESISTANCE_VALUE = 19
  SKINS = ["Classic", "DSx", "White DSx"].freeze
  SKIN_SETTINGS = {
    "Classic" => {
      "espresso_pressure" => {title: "Pressure", color: "rgb(5, 199, 147)", suffix: " bar", type: "spline"},
      "espresso_pressure_goal" => {title: "Pressure Goal", color: "rgb(3, 99, 74)", suffix: " bar", dashed: true, type: "spline"},
      "espresso_water_dispensed" => {title: "Water Dispensed", color: "rgb(31, 183, 234)", suffix: " ml", hidden: true, type: "spline"},
      "espresso_weight" => {title: "Weight", color: "rgb(143, 100, 0)", suffix: " g", hidden: true, type: "spline"},
      "espresso_flow" => {title: "Flow", color: "rgb(31, 183, 234)", suffix: " ml/s", type: "spline"},
      "espresso_flow_weight" => {title: "Weight Flow", color: "rgb(143, 100, 0)", suffix: " g/s", type: "spline"},
      "espresso_flow_goal" => {title: "Flow Goal", color: "rgb(9, 72, 93)", suffix: " ml/s", dashed: true, type: "spline"},
      "espresso_resistance" => {title: "Resistance", color: "rgb(229, 229, 0)", suffix: " lΩ", hidden: true, type: "spline"},
      "espresso_temperature_basket" => {title: "Temperature Basket", color: "rgb(231, 50, 73)", suffix: " °C", type: "spline"},
      "espresso_temperature_mix" => {title: "Temperature Mix", color: "rgb(206, 18, 62)", suffix: " °C", type: "spline"},
      "espresso_temperature_goal" => {title: "Temperature Goal", color: "rgb(150, 13, 45)", suffix: " °C", dashed: true, type: "spline"}
    },
    "DSx" => {
      "espresso_pressure" => {title: "Pressure", color: "rgb(24, 195, 126)", suffix: " bar"},
      "espresso_pressure_goal" => {title: "Pressure Goal", color: "rgb(105, 253, 179)", suffix: " bar", dashed: true},
      "espresso_weight" => {title: "Weight Flow", color: "rgb(162, 105, 61)", suffix: " g", hidden: true},
      "espresso_flow" => {title: "Flow", color: "rgb(78, 133, 244)", suffix: " ml/s"},
      "espresso_flow_weight" => {title: "Weight", color: "rgb(162, 105, 61)", suffix: " g/s"},
      "espresso_flow_goal" => {title: "Flow Goal", color: "rgb(122, 170, 255)", suffix: " ml/s", dashed: true},
      "espresso_resistance" => {title: "Resistance", color: "rgb(229, 229, 0)", suffix: " lΩ", hidden: true},
      "espresso_temperature_basket" => {title: "Temperature Basket", color: "rgb(231, 50, 73)", suffix: " °C"},
      "espresso_temperature_mix" => {title: "Temperature Mix", color: "rgb(255, 153, 0)", suffix: " °C"},
      "espresso_temperature_goal" => {title: "Temperature Goal", color: "rgb(231, 50, 73)", suffix: " °C", dashed: true}
    }
  }.freeze

  attr_reader :shot, :skin, :processed_shot_data

  def initialize(shot, skin: nil)
    @shot = shot
    @skin = SKIN_SETTINGS[skin.present? ? skin.split.last : "Classic"]
    prepare_chart_data
    @temperature_data, @main_data = processed_shot_data.sort.partition { |key, _v| key.include?("temperature") }
  end

  def shot_chart
    for_highcharts(@main_data)
  end

  def temperature_chart
    for_highcharts(@temperature_data)
  end

  memoize def stages
    indices = shot.data.key?("espresso_state_change") ? stages_from_state_change(shot.data["espresso_state_change"]) : detect_stages_from_data(shot.data)
    processed_shot_data.first.second.values_at(*indices).map { |d| {value: d.first} }
  end

  private

  def prepare_chart_data
    @processed_shot_data = process_data(shot)
    @processed_shot_data["espresso_resistance"] = resistance_chart(@processed_shot_data["espresso_pressure"], @processed_shot_data["espresso_flow"])
  end

  def for_highcharts(data)
    data.filter_map do |label, d|
      setting = setting_for(label)
      next if setting.blank?

      {
        name: setting[:title],
        data: d,
        color: setting[:color],
        visible: !setting[:hidden],
        dashStyle: setting[:dashed] ? "Dash" : "Solid",
        tooltip: {
          valueDecimals: 2,
          valueSuffix: setting[:suffix]
        },
        opacity: 0.8,
        type: setting[:type]
      }
    end
  end

  def setting_for(label)
    skin[label]
  end

  def resistance_chart(pressure_data, flow_data)
    pressure_data.map.with_index do |(t, v), i|
      f = flow_data[i].second.to_f
      if f.zero?
        v = nil
      else
        r = v.to_f / f
        v = r > MAX_RESISTANCE_VALUE ? nil : r
      end
      [t, v]
    end
  end

  def stages_from_state_change(data)
    indices = []
    current = data.find { |s| !s.to_i.zero? }
    data.each.with_index do |s, i|
      next if s.to_i.zero? || s == current

      indices << i
      current = s
    end
    indices
  end

  def process_data(shot, label_suffix: nil)
    timeframe = shot.timeframe
    timeframe_count = timeframe.count
    timeframe_last = timeframe.last.to_f
    timeframe_diff = (timeframe_last + timeframe.first.to_f) / timeframe.count.to_f
    shot.data.filter_map do |label, data|
      next if DATA_LABELS_TO_IGNORE.include?(label)

      times10 = label == "espresso_water_dispensed"
      fahrenheit = shot.fahrenheit? && label.include?("temperature")
      data = data.map.with_index do |v, i|
        t = i < timeframe_count ? timeframe[i] : timeframe_last + ((i - timeframe_count + 1) * timeframe_diff)
        v = v.to_f
        v *= 10 if times10
        v = (v - 32) * 5 / 9 if fahrenheit
        v = nil if v.negative?
        [t.to_f * 1000, v]
      end
      [[label, label_suffix].join, data]
    end.to_h
  end

  def detect_stages_from_data(data)
    indices = []
    data.select { |label, _| label.end_with?("_goal") }.each do |_, d|
      d = d.map(&:to_f)
      d.each.with_index do |a, i|
        next if i < 5

        b = d[i - 1]
        c = d[i - 2]
        diff2 = ((a - b) - (b - c))
        indices << i if diff2.abs > 0.1
      end
    end

    if indices.any?
      indices = indices.sort.uniq
      selected = [indices.first]
      indices.each do |index|
        selected << index if (index - selected.last) > 5
      end
    end
    selected
  end
end
