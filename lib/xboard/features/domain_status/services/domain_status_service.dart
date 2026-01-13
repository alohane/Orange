import 'package:fl_clash/xboard/core/core.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';

// NEW: storage + module initializer (fallback)
import 'package:fl_clash/xboard/services/storage/xboard_storage_service.dart';
import 'package:fl_clash/xboard/config/core/module_initializer.dart';
import 'package:fl_clash/xboard/infrastructure/storage/shared_prefs_storage.dart';

final _logger = FileLogger('domain_status_service.dart');

/// 域名状态服务
///
/// 负责域名检测、状态管理和XBoard服务初始化
class DomainStatusService {
  bool _isInitialized = false;

  /// 初始化服务
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      _logger.info('开始初始化');

      // ✅ Always try inject storage (best effort)
      await _ensureStorageInjected();

      // 确保V2配置模块已初始化
      if (!XBoardConfig.isInitialized) {
        _logger.info('XBoardConfig 未初始化，开始初始化...');
        await XBoardConfig.initialize();
      }

      _logger.info('V2配置模块初始化成功');

      _isInitialized = true;
      _logger.info('初始化完成');
    } catch (e) {
      _logger.error('初始化失败', e);
      rethrow;
    }
  }

  /// Ensure storage is injected (fallback if main.dart didn't do it)
  Future<void> _ensureStorageInjected() async {
    try {
      // Check if already injected
      final status = ModuleInitializer.getInitializationStatus();
      if (status['hasStorageService'] == true) {
        _logger.info('Storage service already injected');
        return;
      }

      _logger.info('Injecting storage service...');
      final storageInterface = await SharedPrefsStorage.create();

      final storageService = XBoardStorageService(storageInterface);
      ModuleInitializer.setStorageService(storageService);

      _logger.info('Storage service injected successfully');
    } catch (e) {
      _logger.warning('Failed to inject storage service: $e');
      _logger.info('Continuing without cache support');
      // Don't throw - service can work without cache
    }
  }

  /// 检查域名状态
  Future<Map<String, dynamic>> checkDomainStatus() async {
    if (!_isInitialized) {
      await initialize();
    }

    try {
      _logger.info('开始检查域名状态');

      // Force refresh config (triggers cache fallback)
      try {
        await XBoardConfig.refresh();
        _logger.info('配置刷新成功');
      } catch (e) {
        _logger.error('配置刷新失败:  $e');
        return {
          'success': false,
          'domain': null,
          'latency': null,
          'availableDomains': <String>[],
          'message': '无法加载配置:  $e',
        };
      }

      // Get available domains from config
      final availableDomains = XBoardConfig.allPanelUrls;

      if (availableDomains.isEmpty) {
        _logger.warning('配置中没有可用域名');
        return {
          'success': false,
          'domain': null,
          'latency': null,
          'availableDomains': <String>[],
          'message': '配置中没有可用域名',
        };
      }

      // ✅ FIX: Try racing, but don't fail init if it fails
      final startTime = DateTime.now();
      final bestDomain = await XBoardConfig.getFastestPanelUrl();
      final endTime = DateTime.now();
      final latency = endTime.difference(startTime).inMilliseconds;

      if (bestDomain != null && bestDomain.isNotEmpty) {
        await _initializeXBoardService(bestDomain);
        _logger.info('域名检查成功:   $bestDomain (${latency}ms)');

        return {
          'success': true,
          'domain': bestDomain,
          'latency': latency,
          'availableDomains': availableDomains,
          'message': null,
        };
      } else {
        // ✅ Racing failed (offline), use first domain from config
        final fallbackDomain = availableDomains.first;
        _logger.warning('域名竞速失败，使用缓存域名: $fallbackDomain');

        await _initializeXBoardService(fallbackDomain);

        return {
          'success': true, // ✅ Return success with cached domain!
          'domain': fallbackDomain,
          'latency': null,
          'availableDomains': availableDomains,
          'message': 'offline_mode', // ✅ Flag for offline
        };
      }
    } catch (e) {
      _logger.error('域名检查失败', e);
      return {
        'success': false,
        'domain': null,
        'latency': null,
        'availableDomains': <String>[],
        'message': '域名检查失败: $e',
      };
    }
  }

  /// 刷新域名缓存
  Future<void> refreshDomainCache() async {
    if (!_isInitialized) {
      await initialize();
    }

    try {
      _logger.info('刷新域名缓存');
      await XBoardConfig.refresh();
    } catch (e) {
      _logger.error('刷新缓存失败', e);
      rethrow;
    }
  }

  /// 验证特定域名
  Future<bool> validateDomain(String domain) async {
    if (!_isInitialized) {
      await initialize();
    }

    try {
      _logger.info('验证域名: $domain');
      final availableDomains = XBoardConfig.allPanelUrls;
      return availableDomains.contains(domain);
    } catch (e) {
      _logger.error('域名验证失败', e);
      return false;
    }
  }

  /// 获取统计信息
  Map<String, dynamic> getStatistics() {
    return XBoardConfig.stats;
  }

  /// 初始化XBoard服务
  Future<void> _initializeXBoardService(String domain) async {
    try {
      _logger.info('初始化XBoard服务: $domain');
      _logger.info('XBoard服务将在需要时自动初始化');
    } catch (e) {
      _logger.error('XBoard服务检查失败', e);
    }
  }

  /// 释放资源
  void dispose() {
    _logger.info('释放资源');
    _isInitialized = false;
  }
}
