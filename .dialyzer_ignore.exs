# Accepted dialyzer warnings, each with a reason.
[
  # Success-typing over-narrows Engine.run/4 at the sub-flux call site and
  # concludes the :paused branch is unreachable. The engine contract says
  # otherwise; the defensive clause stays.
  {"lib/flux/workflows.ex", :pattern_match}
]
