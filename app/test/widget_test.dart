import 'package:flutter_test/flutter_test.dart';

import 'package:ai_buddy_biz/services/catalog.dart';

void main() {
  test('EAN-13 check digit', () {
    expect(ean13CheckDigit('400638133393'), 1); // 4006381333931
    expect(isValidEan13('4006381333931'), isTrue);
    expect(isValidEan13('4006381333932'), isFalse);
    expect(isValidEan13('12345'), isFalse);
  });

  test('generated in-store barcodes are valid EAN-13 starting with 2', () {
    for (var i = 0; i < 50; i++) {
      final c = generateInStoreEan13();
      expect(c.length, 13);
      expect(c.startsWith('2'), isTrue);
      expect(isValidEan13(c), isTrue);
    }
  });
}
