///|
/// Recognizing image files by their content.
///
/// A file's name is a claim; its first bytes are evidence. The check is on the bytes because the
/// case that matters is the one where they disagree: a screenshot saved without an extension, or
/// a `.txt` that is really a PNG. Deciding by extension would refuse the first and hand the second
/// to the text reader, which then reports "not UTF-8 text" about a file the model could have been
/// shown.
///
/// The signatures are the same four upstream accepts, so an image that works there works here. Nothing
/// here decodes the image: what the model needs is the bytes, and the provider is what turns them
/// into something the model can look at.

///|
/// What a byte range at the start of a file looks like.
pub(all) enum ImageKind {
  Png
  Jpeg
  Gif
  Webp
} derive(Eq, Debug)

///|
/// The media type to send for this kind of image.
pub fn ImageKind::mime_type(self : ImageKind) -> String {
  match self {
    Png => "image/png"
    Jpeg => "image/jpeg"
    Gif => "image/gif"
    Webp => "image/webp"
  }
}

///|
/// How many bytes are needed to recognize every signature below. A file shorter than this is not
/// one of them: the longest check reads a four-byte marker at offset 8.
pub fn image_signature_bytes() -> Int {
  12
}

///|
/// The image a file starts with, or `None` when it starts with something else.
///
/// Answering `None` is not a claim that the file is text — only that it is not an image this build
/// can send. The caller decides what to do about that, which for the read tool means falling back
/// to the text path and letting its own "not UTF-8 text" answer stand.
pub fn sniff_image(head : Bytes) -> ImageKind? {
  if starts_with(head, 0, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) {
    return Some(Png)
  }
  if starts_with(head, 0, [0xff, 0xd8, 0xff]) {
    return Some(Jpeg)
  }
  // GIF87a and GIF89a: both are GIF, and the version byte is not something the caller needs.
  if starts_with(head, 0, [0x47, 0x49, 0x46, 0x38, 0x37, 0x61]) ||
    starts_with(head, 0, [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]) {
    return Some(Gif)
  }
  // WebP is a RIFF container: `RIFF` at 0, the size at 4, and `WEBP` at 8. Both markers are
  // required, because `RIFF` alone is also WAV and AVI.
  if starts_with(head, 0, [0x52, 0x49, 0x46, 0x46]) &&
    starts_with(head, 8, [0x57, 0x45, 0x42, 0x50]) {
    return Some(Webp)
  }
  None
}

///|
/// Whether `expected` appears at `offset`.
///
/// A short buffer answers `false` rather than raising: a file too small to hold a signature is
/// simply not that format, which is a normal thing to discover about a one-byte file.
fn starts_with(data : Bytes, offset : Int, expected : Array[Int]) -> Bool {
  if data.length() < offset + expected.length() {
    return false
  }
  for i in 0..<expected.length() {
    if data[offset + i].to_int() != expected[i] {
      return false
    }
  }
  true
}
