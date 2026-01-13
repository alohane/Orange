import 'service_locator.dart';
import 'config_settings.dart';
import '../fetchers/remote_config_manager.dart';
import '../parsers/configuration_parser.dart';
import '../internal/xboard_config_accessor.dart';
import '../services/online_support_service.dart';
import '../../core/core.dart';
import '../../services/storage/xboard_storage_service.dart';

final _logger = FileLogger('module_initializer.dart');

class ModuleInitializer {
  static bool _isInitialized = false;

  static XBoardStorageService? _storageService;

  static void setStorageService(XBoardStorageService storage) {
    _storageService = storage;
  }

  static Future<void> initialize({ConfigSettings? settings}) async {
    if (_isInitialized) {
      _logger.warning('Module already initialized');
      return;
    }

    final config = settings ?? const ConfigSettings();

    try {
      if (!config.validate()) {
        final errors = config.getValidationErrors();
        throw Exception('Invalid configuration: ${errors.join(', ')}');
      }

      _configureLogger(config.log);

      _logger.info('Initializing XBoard Config Module V2');
      _logger.info('Current provider: ${config.currentProvider}');

      await _registerServices(config);

      ServiceLocator.markInitialized();
      _isInitialized = true;

      _logger.info('Module initialization completed');
    } catch (e) {
      _logger.error('Module initialization failed', e);
      rethrow;
    }
  }

  static void reset() {
    _logger.info('Resetting module');
    ServiceLocator.reset();
    _isInitialized = false;
    _storageService = null;
  }

  static bool get isInitialized => _isInitialized;

  static Map<String, dynamic> getInitializationStatus() {
    return {
      'initialized': _isInitialized,
      'serviceLocator': ServiceLocator.getStats(),
      'hasStorageService': _storageService != null,
    };
  }

  static void _configureLogger(LogSettings logSettings) {
    _logger.debug('Logger配置：${logSettings.level}');
  }

  static Future<void> _registerServices(ConfigSettings config) async {
    _logger.debug('Registering services');

    ServiceLocator.registerSingleton<ConfigSettings>(config);

    ServiceLocator.registerLazySingleton<RemoteConfigManager>(() {
      _logger.info(
        'Creating RemoteConfigManager with ${config.remoteConfig.sources.length} sources',
      );

      if (_storageService != null) {
        _logger.info('Cache support enabled');
        return RemoteConfigManager.fromSettings(
          config.remoteConfig,
          loadCachedJson: () async {
            _logger.debug('Loading cached config...');
            final result = await _storageService!.getRemoteConfigJson();
            return result.dataOrNull;
          },
          persistCachedJson: (json) async {
            _logger.debug('Persisting config to cache...');
            await _storageService!.saveRemoteConfigJson(json);
          },
          clearCachedJson: () async {
            _logger.debug('Clearing config cache...');
            await _storageService!.clearRemoteConfigCache();
          },
        );
      } else {
        _logger.warning('Cache support disabled (no storage service)');
        return RemoteConfigManager.fromSettings(config.remoteConfig);
      }
    });

    ServiceLocator.registerLazySingleton<ConfigurationParser>(() {
      return ConfigurationParser();
    });

    ServiceLocator.registerLazySingleton<XBoardConfigAccessor>(() {
      return XBoardConfigAccessor(
        remoteManager: ServiceLocator.get<RemoteConfigManager>(),
        parser: ServiceLocator.get<ConfigurationParser>(),
        currentProvider: config.currentProvider,
      );
    });

    ServiceLocator.registerLazySingleton<OnlineSupportService>(() {
      try {
        final accessor = ServiceLocator.get<XBoardConfigAccessor>();
        final configs = accessor.getOnlineSupportConfigs();
        return OnlineSupportService(configs);
      } catch (e) {
        _logger.warning(
          'Failed to initialize OnlineSupportService, using empty config',
          e,
        );
        return OnlineSupportService([]);
      }
    });

    _logger.debug('Services registered successfully');
  }

  static Future<void> warmUp() async {
    if (!_isInitialized) {
      throw StateError('Module not initialized');
    }

    _logger.info('Warming up services');

    try {
      final accessor = ServiceLocator.get<XBoardConfigAccessor>();
      await accessor.refreshConfiguration();

      _logger.info('Services warmed up successfully');
    } catch (e) {
      _logger.warning('Service warm-up failed', e);
    }
  }

  static Future<XBoardConfigAccessor> createConfigAccessor({
    ConfigSettings? settings,
    bool autoWarmUp = true,
  }) async {
    await initialize(settings: settings);

    final accessor = ServiceLocator.get<XBoardConfigAccessor>();

    if (autoWarmUp) {
      await accessor.refreshConfiguration();
    }

    return accessor;
  }
}
