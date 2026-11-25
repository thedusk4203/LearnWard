import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Pure-Dart cryptographic helpers for [ParentGateService] v2.
///
/// Implements PKCS #5 / RFC 7914-referenced PBKDF2-HMAC-SHA-256, CSPRNG salt
/// and attempt-ID generation, constant-time byte comparison, and legacy v1
/// salted SHA-256 verification.
abstract final class ParentGateCrypto {
  /// Production minimum iteration floor for PBKDF2-HMAC-SHA-256.
  static const int productionMinIterations = 100000;

  /// Derived key length in bytes (256-bit).
  static const int defaultKeyLengthBytes = 32;

  /// CSPRNG salt length in bytes (128-bit).
  static const int defaultSaltLengthBytes = 16;

  /// KDF algorithm identifier persisted in `parent_gate_credential_v2`.
  static const String kdfAlgorithmId = 'pbkdf2-hmac-sha256';

  static final Random _secureRandom = Random.secure();

  /// Generates [byteLength] cryptographically secure random bytes.
  static Uint8List generateRandomBytes([
    int byteLength = defaultSaltLengthBytes,
  ]) {
    if (byteLength <= 0) {
      throw ArgumentError.value(byteLength, 'byteLength', 'Must be positive.');
    }
    final bytes = Uint8List(byteLength);
    for (var i = 0; i < byteLength; i++) {
      bytes[i] = _secureRandom.nextInt(256);
    }
    return bytes;
  }

  /// Generates [byteLength] CSPRNG bytes encoded as lowercase hex.
  static String generateRandomHex([int byteLength = defaultSaltLengthBytes]) {
    return bytesToHex(generateRandomBytes(byteLength));
  }

  /// Encodes [bytes] as lowercase hex.
  static String bytesToHex(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write((byte & 0xff).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// Strictly decodes a non-empty even-length hex string, returning `null` if malformed.
  static Uint8List? tryHexToBytes(String hex) {
    if (hex.isEmpty || hex.length.isOdd) {
      return null;
    }
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      final chunk = hex.substring(i * 2, i * 2 + 2);
      final parsed = int.tryParse(chunk, radix: 16);
      if (parsed == null) {
        return null;
      }
      result[i] = parsed;
    }
    return result;
  }

  /// Constant-time comparison of two byte sequences.
  static bool constantTimeEqualsBytes(List<int> a, List<int> b) {
    var diff = a.length ^ b.length;
    final maxLen = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < maxLen; i++) {
      diff |= (a[i] & 0xff) ^ (b[i] & 0xff);
    }
    return diff == 0;
  }

  /// Constant-time comparison of two lowercase hex digests or strings.
  static bool constantTimeEqualsHex(String a, String b) {
    return constantTimeEqualsBytes(utf8.encode(a), utf8.encode(b));
  }

  /// Computes legacy v1 salted SHA-256 hex digest (`utf8('$salt:$pin')`).
  static String sha256V1PinHex({required String pin, required String salt}) {
    return sha256.convert(utf8.encode('$salt:$pin')).toString();
  }

  /// Derives a key with PBKDF2-HMAC-SHA-256, offloading to a worker isolate when [runInIsolate] is `true`.
  static Future<Uint8List> pbkdf2HmacSha256({
    required List<int> password,
    required List<int> salt,
    required int iterations,
    int keyLengthBytes = defaultKeyLengthBytes,
    bool runInIsolate = true,
  }) {
    final passwordCopy = Uint8List.fromList(password);
    final saltCopy = Uint8List.fromList(salt);
    if (!runInIsolate) {
      return Future<Uint8List>.value(
        pbkdf2HmacSha256Sync(
          password: passwordCopy,
          salt: saltCopy,
          iterations: iterations,
          keyLengthBytes: keyLengthBytes,
        ),
      );
    }
    return Isolate.run(
      () => pbkdf2HmacSha256Sync(
        password: passwordCopy,
        salt: saltCopy,
        iterations: iterations,
        keyLengthBytes: keyLengthBytes,
      ),
    );
  }

  /// Synchronous PBKDF2-HMAC-SHA-256 implementation (PKCS #5 v2.1 / RFC 8018 §5.2).
  static Uint8List pbkdf2HmacSha256Sync({
    required List<int> password,
    required List<int> salt,
    required int iterations,
    int keyLengthBytes = defaultKeyLengthBytes,
  }) {
    if (iterations <= 0) {
      throw ArgumentError.value(iterations, 'iterations', 'Must be >= 1.');
    }
    if (keyLengthBytes <= 0) {
      throw ArgumentError.value(
        keyLengthBytes,
        'keyLengthBytes',
        'Must be >= 1.',
      );
    }

    const hashLen = 32; // SHA-256 output size in bytes.
    final blockCount = (keyLengthBytes + hashLen - 1) ~/ hashLen;
    final output = Uint8List(keyLengthBytes);
    final hmac = Hmac(sha256, password);
    final blockInput = Uint8List(salt.length + 4);
    blockInput.setRange(0, salt.length, salt);

    var outputOffset = 0;
    for (var blockIndex = 1; blockIndex <= blockCount; blockIndex++) {
      blockInput[salt.length] = (blockIndex >> 24) & 0xff;
      blockInput[salt.length + 1] = (blockIndex >> 16) & 0xff;
      blockInput[salt.length + 2] = (blockIndex >> 8) & 0xff;
      blockInput[salt.length + 3] = blockIndex & 0xff;

      var u = hmac.convert(blockInput).bytes;
      final t = Uint8List.fromList(u);

      for (var iter = 2; iter <= iterations; iter++) {
        u = hmac.convert(u).bytes;
        for (var j = 0; j < hashLen; j++) {
          t[j] ^= u[j];
        }
      }

      final remaining = keyLengthBytes - outputOffset;
      final copyLen = remaining < hashLen ? remaining : hashLen;
      output.setRange(outputOffset, outputOffset + copyLen, t);
      outputOffset += copyLen;
    }

    return output;
  }
}
