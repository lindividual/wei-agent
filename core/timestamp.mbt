///|
/// ISO 8601 timestamps for session entries.
///
/// Session entries carry a string timestamp (`2026-06-06T11:17:21.709Z`) while
/// messages carry epoch milliseconds. Formatting is pure logic, so it lives here
/// rather than in the platform layer: a session written on one backend has to be
/// readable on another.

///|
fn is_leap(year : Int) -> Bool {
  (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

///|
fn days_in_month(year : Int, month : Int) -> Int {
  match month {
    1 | 3 | 5 | 7 | 8 | 10 | 12 => 31
    4 | 6 | 9 | 11 => 30
    2 => if is_leap(year) { 29 } else { 28 }
    _ => 0
  }
}

///|
fn pad(value : Int, width : Int) -> String {
  let digits = value.to_string()
  let needed = width - digits.length()
  if needed <= 0 {
    digits
  } else {
    let out = StringBuilder()
    for _ in 0..<needed {
      out.write_string("0")
    }
    out.write_string(digits)
    out.to_string()
  }
}

///|
/// Format epoch milliseconds as upstream writes them: UTC, millisecond precision,
/// trailing `Z`.
pub fn format_iso_utc(ms : Int64) -> String {
  let total_seconds = ms / 1000
  let millis = (ms % 1000).to_int()
  let days = total_seconds / 86400
  let second_of_day = total_seconds % 86400
  let hour = (second_of_day / 3600).to_int()
  let minute = (second_of_day % 3600 / 60).to_int()
  let second = (second_of_day % 60).to_int()

  let mut year = 1970
  let mut remaining = days
  while true {
    let year_length = (if is_leap(year) { 366 } else { 365 }).to_int64()
    if remaining < year_length {
      break
    }
    remaining -= year_length
    year += 1
  }
  let mut month = 1
  while true {
    let month_length = days_in_month(year, month).to_int64()
    if remaining < month_length {
      break
    }
    remaining -= month_length
    month += 1
  }
  let day = remaining.to_int() + 1

  "\{pad(year, 4)}-\{pad(month, 2)}-\{pad(day, 2)}T\{pad(hour, 2)}:\{pad(minute, 2)}:\{pad(second, 2)}.\{pad(millis, 3)}Z"
}

///|
/// Parse the `YYYY-MM-DDTHH:MM:SS.mmmZ` form this module writes.
///
/// Returns `None` rather than raising: a session file may have come from another
/// tool or been hand-edited, and a malformed timestamp on an optional field
/// should not make the whole session unreadable.
pub fn parse_iso_utc(text : String) -> Int64? {
  if text.length() < 19 {
    return None
  }
  if text[4] != '-' || text[7] != '-' || text[10] != 'T' {
    return None
  }
  fn digits(from : Int, count : Int) -> Int? {
    let mut value = 0
    for i in from..<(from + count) {
      let c = text[i]
      if c < '0' || c > '9' {
        return None
      }
      value = value * 10 + (c.to_int() - 48)
    }
    Some(value)
  }
  let year = match digits(0, 4) {
    Some(v) => v
    None => return None
  }
  let month = match digits(5, 2) {
    Some(v) => v
    None => return None
  }
  let day = match digits(8, 2) {
    Some(v) => v
    None => return None
  }
  let hour = match digits(11, 2) {
    Some(v) => v
    None => return None
  }
  let minute = match digits(14, 2) {
    Some(v) => v
    None => return None
  }
  let second = match digits(17, 2) {
    Some(v) => v
    None => return None
  }
  let millis = if text.length() >= 23 && text[19] == '.' {
    match digits(20, 3) {
      Some(v) => v
      None => 0
    }
  } else {
    0
  }

  // Days since the epoch, counting whole years then whole months.
  let mut days : Int64 = 0
  for y in 1970..<year {
    days += if is_leap(y) { 366 } else { 365 }
  }
  for m in 1..<month {
    days += days_in_month(year, m).to_int64()
  }
  days += (day - 1).to_int64()

  let seconds = days * 86400 + (hour * 3600 + minute * 60 + second).to_int64()
  Some(seconds * 1000 + millis.to_int64())
}
