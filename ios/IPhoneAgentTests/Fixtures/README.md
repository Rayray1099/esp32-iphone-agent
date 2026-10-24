# Regression fixtures

Decoder fixtures below are synthetic. The three JPEGs contain only cropped
keyboard keys or an input-source menu from an authorized physical test. All
surrounding phone content is replaced with a solid background.

- english-keyboard.jpg: grouped QWERTY letters in an iOS keyboard.
- zhuyin-keyboard.jpg: glyph OCR ambiguity plus the small 注 space-bar label.
- english-source-menu.jpg: every language is listed; only English is selected.
  This catches accepting an unselected English label in a language menu.

- tiny.h264: one 32 x 32 picture, for CPU decoding and timestamp checks.
- interframes.h264: 120 High-profile pictures, for sustained flush ownership.
- cabac-long-term.h264: four 32 x 32 High-profile CABAC pictures. The IDR
  occupies long-term index 0; each following picture explicitly selects the
  previous index, then marks itself at the next index using MMCO 4/6.
  This exercises nonzero LongTermPicNum in the decoder's CABAC reorder path.
- cabac-long-term.rgb: all four independently decoded RGB24 pictures in order,
  3,072 bytes per picture, generated with FFmpeg 8.0:

      ffmpeg -i cabac-long-term.h264 -pix_fmt rgb24 -f rawvideo cabac-long-term.rgb

The CABAC stream derives from FFmpeg's testsrc2=size=32x32:rate=5:duration=2
encoded with libx264, High profile, no B pictures, one reference, no weighted
prediction, one slice, no AUD, and a long key interval. Its SPS reserves four
references. Slice-header reference modifications and MMCO operands are replaced,
then CABAC alignment is regenerated without altering the entropy-coded payload.
Only the first four pictures are retained. With correct reference numbering the
decoded YUV matches FFmpeg byte for byte. With only the flush ownership patch,
picture four's mean RGB error is 5.57 despite status zero.
