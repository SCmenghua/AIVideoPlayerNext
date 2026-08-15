class AppBuildInfo {
  const AppBuildInfo._();

  static const version = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '0.1.0',
  );
  static const buildTime = String.fromEnvironment(
    'APP_BUILD_TIME',
    defaultValue: '开发构建',
  );
  static const buildId = String.fromEnvironment(
    'APP_BUILD_ID',
    defaultValue: '未指定',
  );

  static String get label =>
      '版本 $version · 构建时间 $buildTime · 构建编号 $buildId';
}
