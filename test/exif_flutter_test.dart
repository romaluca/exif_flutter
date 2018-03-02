import 'dart:io';
import 'package:test/test.dart';

import 'package:exif_flutter/exif_flutter.dart';

void main() {
  test('test exif', () {
    var answer = 42;
    expect(answer, 42);
    File f = new File('test.jpg');
    
    readExifFromFile(f, true).then((data) {
      print("exif params: $data");
    }).catchError((e) {
      print("exif error: $e");
      
    });
    /*
    final calculator = new Calculator();
    expect(calculator.addOne(2), 3);
    expect(calculator.addOne(-7), -6);
    expect(calculator.addOne(0), 1);
    expect(() => calculator.addOne(null), throwsNoSuchMethodError);
    */
  });
}
