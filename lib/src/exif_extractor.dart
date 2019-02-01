import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:typed_data";

//import "dart:html";

import "blob_view.dart";
import "constants.dart";
import "log_message_sink.dart";


class Rational {
  Rational(this.numerator, this.denominator);

  double toDouble() => numerator / denominator;

  @override
  String toString() => toDouble().toString();

  Map<String, int> toJson() => <String, int>{
        "numerator": numerator,
        "denominator": denominator,
      };

  final int numerator;
  final int denominator;
}

Future<Map<String, dynamic>> readExifFromFile(File file, [bool printDebugInfo=false]) {
  return new ExifExtractor(printDebugInfo ? new ConsoleMessageSink() : null)
      .findEXIFinJPEG(new BlobView(file)) ?? <String, dynamic>{};
}

class ConsoleMessageSink implements LogMessageSink {
  @override
  void log(Object message, [List<Object> additional]) {
    if (message == null) message = "null";
    if (additional != null) message = "$message $additional";
    print(message);
  }
}

class ExifExtractor {
  ExifExtractor(this.debug);

  Future<Map<String, dynamic>> findEXIFinJPEG(BlobView dataView) async {
    if (debug != null) debug.log("Got file of length ${dataView.byteLength}");
    if ((await dataView.getUint8(0) != 0xFF) ||
        (await dataView.getUint8(1) != 0xD8)) {
      if (debug != null) debug.log("Not a valid JPEG");
      return null; // not a valid jpeg
    }

    int offset = 2;
    final int length = await dataView.byteLength;
    int marker;

    while (offset < length) {
      final int lastValue = await dataView.getUint8(offset);
      if (lastValue != 0xFF) {
        if (debug != null)
          debug.log("Not a valid marker at offset $offset, "
              "found: $lastValue");
        return null; // not a valid marker, something is wrong
      }

      marker = await dataView.getUint8(offset + 1);
      if (debug != null) debug.log(marker);

      // we could implement handling for other markers here,
      // but we're only looking for 0xFFE1 for EXIF data

      if (marker == 225) {
        if (debug != null) debug.log("Found 0xFFE1 marker");

        return readEXIFData(dataView, offset + 4);

        // offset += 2 + file.getShortAt(offset+2, true);

      } else {
        offset += 2 + await dataView.getUint16(offset + 2);
      }
    }

    return null;
  }

  Future<Object> findIPTCinJPEG(BlobView dataView) async {
    if (debug != null) debug.log("Got file of length ${dataView.byteLength}");
    if ((await dataView.getUint8(0) != 0xFF) ||
        (await dataView.getUint8(1) != 0xD8)) {
      if (debug != null) debug.log("Not a valid JPEG");
      return null; // not a valid jpeg
    }

    int offset = 2;
    final int length = await dataView.byteLength;

    const List<int> segmentStartBytes = const <int>[
      0x38,
      0x42,
      0x49,
      0x4D,
      0x04,
      0x04
    ];

    Future<bool> isFieldSegmentStart(BlobView dataView, int offset) async {
      final ByteData data = await dataView.getBytes(offset, offset + 6);
      for (int i = 0; i < 6; ++i) {
        if (data.getUint8(i) != segmentStartBytes[i]) return false;
      }
      return true;
    }

    while (offset < length) {
      if (await isFieldSegmentStart(dataView, offset)) {
        // Get the length of the name header (which is padded to an even number of bytes)
        int nameHeaderLength = await dataView.getUint8(offset + 7);
        if (nameHeaderLength % 2 != 0) nameHeaderLength += 1;
        // Check for pre photoshop 6 format
        if (nameHeaderLength == 0) {
          // Always 4
          nameHeaderLength = 4;
        }

        final int startOffset = offset + 8 + nameHeaderLength;
        final int sectionLength =
            await dataView.getUint16(offset + 6 + nameHeaderLength);

        return readIPTCData(dataView, startOffset, sectionLength);
      }

      // Not the marker, continue searching
      offset++;
    }

    return null;
  }

  Future<Map<String, dynamic>> readTags(BlobView file, int tiffStart,
      int dirStart, Map<int, String> strings, Endian bigEnd) async {
    final int entries = await file.getUint16(dirStart, bigEnd);
    final Map<String, dynamic> tags = <String, dynamic>{};
    int entryOffset;

    for (int i = 0; i < entries; i++) {
      entryOffset = dirStart + i * 12 + 2;
      final int tagId = await file.getUint16(entryOffset, bigEnd);
      final String tag = strings[tagId];
      if (tag == null && debug != null) debug.log("Unknown tag: $tagId");
      if (tag != null) {
        tags[tag] =
            await readTagValue(file, entryOffset, tiffStart, dirStart, bigEnd);
      }
    }
    return tags;
  }

  Future<dynamic> readTagValue(BlobView file, int entryOffset, int tiffStart,
      int dirStart, Endian bigEnd) async {
    final int type = await file.getUint16(entryOffset + 2, bigEnd);
    final int numValues = await file.getUint32(entryOffset + 4, bigEnd);
    final int valueOffset = await file.getUint32(entryOffset + 8, bigEnd) + tiffStart;

    switch (type) {
      case 1: // byte, 8-bit unsigned int
      case 7: // undefined, 8-bit byte, value depending on field
        if (numValues == 1) {
          return file.getUint8(entryOffset + 8);
        } else {
          final int offset = numValues > 4 ? valueOffset : (entryOffset + 8);
          final ByteData bytes = await file.getBytes(offset, offset + numValues);
          final Uint8List result = new Uint8List(numValues);
          for (int i = 0; i < result.length; ++i) result[i] = bytes.getUint8(i);
          return result;
        }
        break;
      case 2: // ascii, 8-bit byte
        final int offset = numValues > 4 ? valueOffset : (entryOffset + 8);
        return getStringFromDB(file, offset, numValues - 1);

      case 3: // short, 16 bit int
        if (numValues == 1) {
          return file.getUint16(entryOffset + 8, bigEnd);
        } else {
          final int offset = numValues > 2 ? valueOffset : (entryOffset + 8);
          final ByteData bytes = await file.getBytes(offset, offset + 2 * numValues);
          final Uint16List result = new Uint16List(numValues);
          for (int i = 0; i < result.length; ++i)
            result[i] = bytes.getUint16(i * 2, bigEnd);
          return result;
        }

        break;

      case 4: // long, 32 bit int
        if (numValues == 1) {
          return file.getUint32(entryOffset + 8, bigEnd);
        } else {
          final int offset = valueOffset;
          final ByteData bytes = await file.getBytes(offset, offset + 4 * numValues);
          final Uint32List result = new Uint32List(numValues);
          for (int i = 0; i < result.length; ++i)
            result[i] = bytes.getUint32(i * 4, bigEnd);
          return result;
        }
        break;
      case 5: // rational = two long values, first is numerator, second is denominator
        if (numValues == 1) {
          final int numerator = await file.getUint32(valueOffset, bigEnd);
          final int denominator = await file.getUint32(valueOffset + 4, bigEnd);
          return new Rational(numerator, denominator);
        } else {
          final int offset = valueOffset;
          final ByteData bytes = await file.getBytes(offset, offset + 8 * numValues);
          final List<Rational> result = new List<Rational>(numValues);
          for (int i = 0; i < result.length; ++i) {
            final int numerator = bytes.getUint32(i * 8, bigEnd);
            final int denominator = bytes.getUint32(i * 8 + 4, bigEnd);
            result[i] = new Rational(numerator, denominator);
          }
          return result;
        }
        break;
      case 9: // slong, 32 bit signed int
        if (numValues == 1) {
          return file.getInt32(entryOffset + 8, bigEnd);
        } else {
          final int offset = valueOffset;
          final ByteData bytes = await file.getBytes(offset, offset + 4 * numValues);
          final Int32List result = new Int32List(numValues);
          for (int i = 0; i < result.length; ++i)
            result[i] = bytes.getInt32(i * 4, bigEnd);
          return result;
        }
        break;
      case 10: // signed rational, two slongs, first is numerator, second is denominator
        if (numValues == 1) {
          final int numerator = await file.getInt32(valueOffset, bigEnd);
          final int denominator = await file.getInt32(valueOffset + 4, bigEnd);
          return new Rational(numerator, denominator);
        } else {
          final int offset = valueOffset;
          final ByteData bytes = await file.getBytes(offset, offset + 8 * numValues);
          final List<Rational> result = new List<Rational>(numValues);
          for (int i = 0; i < result.length; ++i) {
            final int numerator = bytes.getInt32(i * 8, bigEnd);
            final int denominator = bytes.getInt32(i * 8 + 4, bigEnd);
            result[i] = new Rational(numerator, denominator);
          }
          return result;
        }
    }
  }

  Future<String> getStringFromDB(BlobView buffer, int start, int length) async {
    final Utf8Decoder utf8decoder = const Utf8Decoder(allowMalformed: true);
    final ByteData bytes = await buffer.getBytes(start, start + length);
    return utf8decoder.convert(new List<int>.generate(length, (int i) => bytes.getUint8(i)));
  }

  Future<Map<String, dynamic>> readEXIFData(BlobView file, int start) async {
    final String startingString = await getStringFromDB(file, start, 4);
    if (startingString != "Exif") {
      if (debug != null) debug.log("Not valid EXIF data! $startingString");
      return null;
    }

    Endian bigEnd;
    final int tiffOffset = start + 6;

    // test for TIFF validity and endianness
    if (await file.getUint16(tiffOffset) == 0x4949) {
      bigEnd = Endian.little;
    } else if (await file.getUint16(tiffOffset) == 0x4D4D) {
      bigEnd = Endian.big;
    } else {
      if (debug != null)
        debug.log("Not valid TIFF data! (no 0x4949 or 0x4D4D)");
      return null;
    }

    if (await file.getUint16(tiffOffset + 2, bigEnd) != 0x002A) {
      if (debug != null) debug.log("Not valid TIFF data! (no 0x002A)");
      return null;
    }

    final int firstIFDOffset = await file.getUint32(tiffOffset + 4, bigEnd);

    if (firstIFDOffset < 0x00000008) {
      if (debug != null)
        debug.log(
            "Not valid TIFF data! (First offset less than 8) $firstIFDOffset");
      return null;
    }

    final Map<String, dynamic> tags = await readTags(file, tiffOffset,
        tiffOffset + firstIFDOffset, ExifConstants.tiffTags, bigEnd);

    if (tags.containsKey("ExifIFDPointer")) {
      final Map<String, dynamic> exifData = await readTags(file, tiffOffset,
          tiffOffset + tags["ExifIFDPointer"], ExifConstants.tags, bigEnd);
      for (String tag in exifData.keys) {
        switch (tag) {
          case "LightSource":
          case "Flash":
          case "MeteringMode":
          case "ExposureProgram":
          case "SensingMethod":
          case "SceneCaptureType":
          case "SceneType":
          case "CustomRendered":
          case "WhiteBalance":
          case "GainControl":
          case "Contrast":
          case "Saturation":
          case "Sharpness":
          case "SubjectDistanceRange":
          case "FileSource":
            exifData[tag] = ExifConstants.stringValues[tag][exifData[tag]];
            break;

          case "ExifVersion":
          case "FlashpixVersion":
          final Utf8Decoder utf8decoder = const Utf8Decoder();
            exifData[tag] =
                utf8decoder.convert((exifData[tag]).sublist(0, 4));
            break;

          case "ComponentsConfiguration":
            exifData[tag] = ExifConstants.stringValues["Components"]
                    [exifData[tag][0]] +
                ExifConstants.stringValues["Components"][exifData[tag][1]] +
                ExifConstants.stringValues["Components"][exifData[tag][2]] +
                ExifConstants.stringValues["Components"][exifData[tag][3]];
            break;
        }
        tags[tag] = exifData[tag];
      }
    }

    if (tags.containsKey("GPSInfoIFDPointer")) {
      final Map<String, dynamic> gpsData = await readTags(
          file,
          tiffOffset,
          tiffOffset + tags["GPSInfoIFDPointer"],
          ExifConstants.gpsTags,
          bigEnd);
      for (String tag in gpsData.keys) {
        switch (tag) {
          case "GPSVersionID":
            final List<String> version = gpsData[tag];
            gpsData[tag] = version.join(".");
            break;
        }
        tags[tag] = gpsData[tag];
      }
    }

    return tags;
  }

  Future<Map<String, dynamic>> readIPTCData(
      BlobView dataView, int startOffset, int sectionLength) async {
    final Map<String, dynamic> data = <String, dynamic>{};
    int segmentStartPos = startOffset;
    while (segmentStartPos < startOffset + sectionLength) {
      final ByteData bytes =
          await dataView.getBytes(segmentStartPos, segmentStartPos + 5);
      if (bytes.getUint8(0) == 0x1C && bytes.getUint8(1) == 0x02) {
        final int segmentType = bytes.getUint8(2);
        if (ExifConstants.iptcFieldMap.containsKey(segmentType)) {
          final int dataSize = bytes.getInt16(3);
          final String fieldName = ExifConstants.iptcFieldMap[segmentType];
          final String fieldValue =
              await getStringFromDB(dataView, segmentStartPos + 5, dataSize);
          // Check if we already stored a value with this name
          if (data.containsKey(fieldName)) {
            // Value already stored with this name, create multivalue field
            if (data[fieldName] is List) {
              (data[fieldName]).add(fieldValue);
            } else {
              data[fieldName] = <String>[data[fieldName], fieldValue];
            }
          } else {
            data[fieldName] = fieldValue;
          }
        }
      }
      segmentStartPos++;
    }
    return data;
  }

  final LogMessageSink debug;
}
