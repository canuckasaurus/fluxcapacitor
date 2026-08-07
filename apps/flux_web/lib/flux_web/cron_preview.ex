defmodule FluxWeb.CronPreview do
  @moduledoc """
  "When does this fire next?" for cron expressions, using Oban's own
  parser so the preview can never disagree with the scheduler. Scans
  minute-by-minute up to a week out — pure and fast enough for render.
  """

  @minutes_in_week 10_080

  @doc "Next fire as a DateTime (UTC), or nil for invalid/never-soon crons."
  def next_fire(cron, now \\ DateTime.utc_now(:second)) do
    case Oban.Cron.Expression.parse(to_string(cron || "")) do
      {:ok, expression} ->
        start = %{now | second: 0}

        Enum.find_value(1..@minutes_in_week, fn minutes ->
          candidate = DateTime.add(start, minutes, :minute)
          if Oban.Cron.Expression.now?(expression, candidate), do: candidate
        end)

      _invalid ->
        nil
    end
  end

  @doc "Human line for the schedule tables: `next Aug 08 06:00 UTC`."
  def describe(cron, now \\ DateTime.utc_now(:second)) do
    case next_fire(cron, now) do
      nil -> nil
      fire_at -> "next " <> Calendar.strftime(fire_at, "%b %d %H:%M") <> " UTC"
    end
  end
end
