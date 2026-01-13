import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';
import 'dart:ffi' as ffi;

import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/plugins/tile.dart';
import 'package:fl_clash/plugins/vpn.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/infrastructure/network/domain_racing_service.dart';

// Storage + module initializer imports
import 'package:fl_clash/xboard/services/storage/xboard_storage_service.dart';
import 'package:fl_clash/xboard/config/core/module_initializer.dart';
import 'package:fl_clash/xboard/infrastructure/storage/shared_prefs_storage.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'application.dart';
import 'clash/core.dart';
import 'clash/lib.dart';
import 'common/common.dart';
import 'models/models.dart';
import 'package:fl_clash/xboard/features/remote_task/remote_task_manager.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';

RemoteTaskManager? remoteTaskManager;

Future<void> main() async {
  globalState.isService = false;
  WidgetsFlutterBinding.ensureInitialized();

  // STEP 1: Initialize storage FIRST
  await _initializeStorage();

  // STEP 2: Initialize XBoard services (with cache support)
  await _initializeXBoardServices();

  // STEP 3: Initialize RemoteTaskManager
  try {
    remoteTaskManager = await RemoteTaskManager.create();
    if (remoteTaskManager != null) {
      remoteTaskManager!.initialize();
      remoteTaskManager!.start();
      print('RemoteTaskManager 从配置初始化成功');
    } else {
      print('警告: RemoteTaskManager 初始化失败 - 配置中未找到 WebSocket URL');
    }
  } catch (e) {
    print('警告: RemoteTaskManager 初始化异常: $e');
    remoteTaskManager = null;
  }

  // STEP 4: Initialize app
  final version = await system.version;
  await clashCore.preload();
  await globalState.initApp(version);
  await android?.init();
  await window?.init(version);
  HttpOverrides.global = FlClashHttpOverrides();

  // STEP 5: Register lifecycle observer
  WidgetsBinding.instance.addObserver(_AppLifecycleObserver());

  // STEP 6: Run app
  runApp(
    const ProviderScope(
      child: Application(),
    ),
  );
}

/// Initialize storage service
Future<void> _initializeStorage() async {
  try {
    print('[Main] 初始化存储服务...');

    final storageInterface = await SharedPrefsStorage.create();

    final storageService = XBoardStorageService(storageInterface);

    // ✅ DEBUG: Check if cache exists
    final cachedConfig = await storageService.getRemoteConfigJson();
    print('[Main] 缓存检查: ${cachedConfig.dataOrNull != null ? "有缓存" : "无缓存"}');
    if (cachedConfig.dataOrNull != null) {
      print('[Main] 缓存大小: ${cachedConfig.dataOrNull!.length} bytes');
    }

    // CRITICAL: Inject storage BEFORE XBoardConfig.initialize
    ModuleInitializer.setStorageService(storageService);

    print('[Main] 存储服务初始化成功 (cache support enabled)');
  } catch (e) {
    print('[Main] 存储服务初始化失败: $e');
    print('[Main] 应用将继续但无缓存支持');
  }
}

/// Load security config (certificates, UA, etc.)
Future<void> _loadSecurityConfig() async {
  try {
    final certConfig = await ConfigFileLoaderHelper.getCertificateConfig();
    final certPath = certConfig['path'] as String?;
    final certEnabled = certConfig['enabled'] as bool? ?? true;

    if (certEnabled && certPath != null && certPath.isNotEmpty) {
      DomainRacingService.setCertificatePath(certPath);
      print('[Main] 证书路径配置: $certPath');
    }
  } catch (e) {
    print('[Main] 加载安全配置失败: $e');
  }
}

/// Initialize XBoard services
Future<void> _initializeXBoardServices() async {
  try {
    print('[Main] 开始初始化XBoard配置模块...');

    // Load config from file
    final configSettings = await ConfigFileLoader.loadFromFile();
    print('[Main] 配置文件加载成功，Provider: ${configSettings.currentProvider}');

    // Load security config
    await _loadSecurityConfig();
    print('[Main] 安全配置加载成功');

    // Initialize XBoardConfig (with cache support via injected storage)
    await XBoardConfig.initialize(settings: configSettings);
    print('[Main] XBoard配置模块初始化成功');

    print('[Main] SDK 将在应用启动后由 xboardSdkProvider 初始化');
  } catch (e) {
    print('[Main] XBoard服务初始化失败: $e');
    rethrow;
  }
}

/// App lifecycle observer
class _AppLifecycleObserver extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.detached) {
      // Clean up resources when app is killed
      remoteTaskManager?.dispose();
      XBoardSDK.instance.dispose();
      print('应用生命周期状态改变: $state, 所有服务资源已释放');
    }
  }
}

// ==========================================
// Background Service Code (VPN service)
// ==========================================

@pragma('vm:entry-point')
Future<void> _service(List<String> flags) async {
  globalState.isService = true;
  WidgetsFlutterBinding.ensureInitialized();
  final quickStart = flags.contains("quick");
  final clashLibHandler = ClashLibHandler();
  await globalState.init();

  tile?.addListener(
    _TileListenerWithService(
      onStop: () async {
        await app?.tip(appLocalizations.stopVpn);
        clashLibHandler.stopListener();
        await vpn?.stop();
        exit(0);
      },
    ),
  );

  vpn?.handleGetStartForegroundParams = () {
    final traffic = clashLibHandler.getTraffic();
    return json.encode({
      "title": clashLibHandler.getCurrentProfileName(),
      "content": "$traffic",
    });
  };

  vpn?.addListener(
    _VpnListenerWithService(
      onDnsChanged: (String dns) {
        print("handle dns $dns");
        clashLibHandler.updateDns(dns);
      },
    ),
  );

  if (!quickStart) {
    _handleMainIpc(clashLibHandler);
  } else {
    commonPrint.log("quick start");
    await ClashCore.initGeo();
    app?.tip(appLocalizations.startVpn);
    final homeDirPath = await appPath.homeDirPath;
    final version = await system.version;

    final clashConfig = globalState.config.patchClashConfig.copyWith.tun(
      enable: true,
    );

    Future(() async {
      final profileId = globalState.config.currentProfileId;
      if (profileId == null) {
        return;
      }
      final params = await globalState.getSetupParams(
        pathConfig: clashConfig,
      );
      final res = await clashLibHandler.quickStart(
        InitParams(
          homeDir: homeDirPath,
          version: version,
        ),
        params,
        globalState.getCoreState(),
      );
      debugPrint(res);
      if (res.isNotEmpty) {
        await vpn?.stop();
        exit(0);
      }
      await vpn?.start(
        clashLibHandler.getAndroidVpnOptions(),
      );
      clashLibHandler.startListener();
    });
  }
}

void _handleMainIpc(ClashLibHandler clashLibHandler) {
  final sendPort = IsolateNameServer.lookupPortByName(mainIsolate);
  if (sendPort == null) {
    return;
  }

  final serviceReceiverPort = ReceivePort();

  serviceReceiverPort.listen((message) async {
    if (message == null) {
      serviceReceiverPort.close();
      return;
    }

    try {
      final res = await clashLibHandler.invokeAction(message);
      sendPort.send(res);
    } catch (e) {
      sendPort.send({'error': e.toString()});
    }
  });

  // Send service port to main isolate
  sendPort.send(serviceReceiverPort.sendPort);

  // Create a RawReceivePort for native FFI
  final messageRawPort = RawReceivePort((message) {
    sendPort.send(message);
  });

  // Attach using the SendPort's nativePort
  clashLibHandler.attachMessagePort(messageRawPort.sendPort.nativePort);
}

@immutable
class _TileListenerWithService with TileListener {
  final Function() _onStop;

  const _TileListenerWithService({
    required Function() onStop,
  }) : _onStop = onStop;

  @override
  void onStop() {
    _onStop();
  }
}

@immutable
class _VpnListenerWithService with VpnListener {
  final Function(String dns) _onDnsChanged;

  const _VpnListenerWithService({
    required Function(String dns) onDnsChanged,
  }) : _onDnsChanged = onDnsChanged;

  @override
  void onDnsChanged(String dns) {
    super.onDnsChanged(dns);
    _onDnsChanged(dns);
  }
}
