///|
/// Recognizing an image from its first bytes.
///
/// The point of sniffing rather than trusting the name is the disagreement case, so every test
/// here is about a file whose name says one thing and whose bytes say another.

///|
fn bytes_of(values : Array[Int]) -> Bytes {
  let out : Array[Byte] = []
  for v in values {
    out.push(v.to_byte())
  }
  Bytes::from_array(out)
}

///|
fn ascii(text : String) -> Array[Int] {
  let out : Array[Int] = []
  for c in text {
    out.push(c.to_int())
  }
  out
}

///|
test "the four supported formats are recognized by their signatures" {
  assert_eq(
    sniff_image(bytes_of([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])),
    Some(Png),
  )
  assert_eq(sniff_image(bytes_of([0xff, 0xd8, 0xff, 0xe0])), Some(Jpeg))
  assert_eq(sniff_image(bytes_of(ascii("GIF87a"))), Some(Gif))
  assert_eq(sniff_image(bytes_of(ascii("GIF89a"))), Some(Gif))
  let webp = bytes_of(ascii("RIFF") + [0x00, 0x00, 0x00, 0x00] + ascii("WEBP"))
  assert_eq(sniff_image(webp), Some(Webp))
  // The media type is what goes on the wire, so it has to be spelled the way providers expect.
  assert_eq(@core.Png.mime_type(), "image/png")
  assert_eq(@core.Jpeg.mime_type(), "image/jpeg")
  assert_eq(@core.Gif.mime_type(), "image/gif")
  assert_eq(@core.Webp.mime_type(), "image/webp")
}

///|
/// A RIFF container that is not WebP is not an image. WAV and AVI share the first marker, which is
/// why `WEBP` at offset 8 is required and not merely decorative.
test "a RIFF file that is not WebP is not an image" {
  let wav = bytes_of(ascii("RIFF") + [0x24, 0x08, 0x00, 0x00] + ascii("WAVE"))
  assert_true(sniff_image(wav) is None)
  // A truncated RIFF: long enough for the first marker, too short for the second.
  assert_true(sniff_image(bytes_of(ascii("RIFF"))) is None)
}

///|
test "text and other bytes are not images" {
  assert_true(sniff_image(bytes_of(ascii("hello, world"))) is None)
  assert_true(sniff_image(bytes_of(ascii("---\nname: a\n"))) is None)
  assert_true(
    sniff_image(bytes_of(ascii("PK"))) is None,
    msg="a zip is not an image",
  )
  // A one-byte or empty file is simply not any format — not an error.
  assert_true(sniff_image(bytes_of([0x89])) is None)
  assert_true(sniff_image(b"") is None)
}

///|
/// The signature check must not read past what it was given.
///
/// The caller hands over a bounded prefix, so a file shorter than a signature is a normal input.
/// Reading past the end would be an out-of-bounds access rather than a wrong answer.
test "a buffer shorter than a signature is answered, not overrun" {
  let png = ascii("PNG")
  for length in 0..<image_signature_bytes() {
    let upto = if length < png.length() { length } else { png.length() }
    let short : Array[Int] = []
    for i in 0..<upto {
      short.push(png[i])
    }
    let head = bytes_of(short)
    // Must not raise for any short length.
    ignore(sniff_image(head))
  }
  // The declared size is enough for every signature, so a caller that reads that much never gets a
  // false negative from truncation.
  assert_true(image_signature_bytes() >= 12)
}
