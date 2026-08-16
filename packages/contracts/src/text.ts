/**
 * Measures a string in UTF-8 bytes rather than UTF-16 code units.
 *
 * Payload limits are enforced by APNs, FCM and the operating systems in bytes.
 * `String.length` counts code units, so a limit checked with it passes for text
 * that the provider then rejects — emoji and non-Latin scripts are the common
 * cases, which is precisely the text a notification is most likely to contain.
 */
export function utf8ByteLength(value: string): number {
  let bytes = 0;
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code <= 0x7f) bytes += 1;
    else if (code <= 0x7ff) bytes += 2;
    else if (code >= 0xd800 && code <= 0xdbff) {
      // A surrogate pair is one 4-byte character; skip its low surrogate.
      bytes += 4;
      index += 1;
    } else bytes += 3;
  }
  return bytes;
}
