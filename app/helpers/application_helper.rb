module ApplicationHelper
  def format_time(seconds)
    return '0:00' unless seconds&.positive?

    mins, secs = seconds.divmod(60)
    hours, mins = mins.divmod(60)
    if hours > 0
      format('%d:%02d:%02d', hours, mins, secs)
    else
      format('%d:%02d', mins, secs)
    end
  end
end
