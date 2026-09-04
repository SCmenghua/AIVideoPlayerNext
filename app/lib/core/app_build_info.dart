class AppBuildInfo {
  const AppBuildInfo._();

  static const version = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '0.10.0',
  );
  static const buildTime = String.fromEnvironment(
    'APP_BUILD_TIME',
    defaultValue: '开发构建',
  );
  static const buildId = String.fromEnvironment(
    'APP_BUILD_ID',
    defaultValue: '未指定',
  );

  /// Compact panels use this as three independent lines so the timestamp and
  /// build identifier stay visible beside export actions.
  static String get label => '版本 $version\n构建时间 $buildTime\n构建编号 $buildId';
}
