/// Declared compatibility metadata, separate from installation identifiers.
class QidianDeviceProfile {
  const QidianDeviceProfile({
    required this.brand,
    required this.model,
    required this.androidRelease,
    required this.androidApiLevel,
    required this.packageName,
    required this.cpuAbi,
    required this.screenWidth,
    required this.screenHeight,
    required this.screenDiagonalInches,
  });

  // Match native/qidian/client/windows_device_profile.hpp. The model is the
  // public product name, not a device-captured Android Build.MODEL value.
  static const windows = QidianDeviceProfile(
    brand: 'Xiaomi',
    model: 'Xiaomi 17 Pro Max',
    androidRelease: '16',
    androidApiLevel: 36,
    packageName: 'com.qidian.QDReader',
    cpuAbi: 'arm64-v8a',
    screenWidth: 1200,
    screenHeight: 2608,
    screenDiagonalInches: 6.9,
  );

  final String brand, model, androidRelease, packageName, cpuAbi;
  final int androidApiLevel, screenWidth, screenHeight;
  final double screenDiagonalInches;
}
