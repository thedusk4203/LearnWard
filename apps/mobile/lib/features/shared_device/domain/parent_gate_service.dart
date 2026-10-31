import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:learnward_application/learnward_application.dart';

/// Threat Model for Shared-Device Parent Gate:
///
/// - **Context:** LearnWard operates primarily on shared family devices where
///   children (roughly 10–15 years old) complete learning challenges under Child Mode.
/// - **Attacker Profile:** Casual child attempts to bypass the restricted Child Mode
///   UI to access parent settings, view siblings' records, or modify family structure.
/// - **Attack Vectors Addressed:**
///   1. Simple arithmetic challenges (e.g. 7 x 8) are trivial for 10-15 year olds
///      and are completely replaced with parent-defined PIN verification.
///   2. Accidental or intentional app kill/relaunch is prevented from resetting Child Mode
///      because active child session state is persisted locally.
///   3. Deep-link and back-button navigation into parent routes is blocked by the GoRouter guard.
///   4. Reusable PINs are NEVER stored in plaintext in SQLite or SharedPreferences.
///      Only a cryptographically salted SHA-256 digest is retained.
/// - **Out of Scope:** Rooted/jailbroken device extraction or physical forensic analysis.
///   Server-side Row Level Security (RLS) is the actual security boundary for all family data.
class ParentGateService {
  ParentGateService(this._store);

  final LocalMetadataStore _store;

  static const pinHashKey = 'parent_gate_pin_hash';
  static const pinSaltKey = 'parent_gate_pin_salt';

  /// Generates a random 16-byte hex salt.
  String _generateSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Computes a salted SHA-256 hash.
  String _hashPin(String pin, String salt) {
    final bytes = utf8.encode('$salt:$pin');
    return sha256.convert(bytes).toString();
  }

  /// Verifies if the entered PIN matches the configured Parent PIN.
  ///
  /// Fails closed (returns false) if no PIN has been explicitly configured.
  /// Universal default PINs are strictly prohibited.
  Future<bool> verifyPin(String enteredPin) async {
    final salt = await _store.readMetadata(pinSaltKey);
    final storedHash = await _store.readMetadata(pinHashKey);

    if (salt == null || storedHash == null) {
      return false;
    }

    final computedHash = _hashPin(enteredPin, salt);
    return computedHash == storedHash;
  }

  /// Updates or sets a new 4-digit Parent PIN.
  ///
  /// The plaintext PIN is hashed with a cryptographically secure random salt
  /// and is NEVER persisted directly.
  Future<void> setPin(String newPin) async {
    if (newPin.length != 4 || int.tryParse(newPin) == null) {
      throw ArgumentError('Parent PIN must be exactly 4 digits');
    }

    final salt = _generateSalt();
    final hash = _hashPin(newPin, salt);
    final now = DateTime.now().toUtc();

    await _store.writeMetadata(key: pinSaltKey, value: salt, updatedAt: now);
    await _store.writeMetadata(key: pinHashKey, value: hash, updatedAt: now);
  }

  /// Returns whether a parent PIN has been explicitly configured.
  Future<bool> hasConfiguredPin() async {
    final hash = await _store.readMetadata(pinHashKey);
    final salt = await _store.readMetadata(pinSaltKey);
    return hash != null && salt != null;
  }

  /// Alias for [hasConfiguredPin].
  Future<bool> hasCustomPin() => hasConfiguredPin();
}
