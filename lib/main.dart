import 'dart:async';
import 'dart:io';

import 'package:blackhole/Constants/constants.dart';
import 'package:blackhole/Constants/languagecodes.dart';
import 'package:blackhole/Helpers/config.dart';
import 'package:blackhole/Helpers/handle_native.dart';
import 'package:blackhole/Helpers/import_export_playlist.dart';
import 'package:blackhole/Helpers/logging.dart';
import 'package:blackhole/Helpers/route_handler.dart';
import 'package:blackhole/Providers/audio_service_provider.dart';
import 'package:blackhole/Screens/Common/routes.dart';
import 'package:blackhole/Screens/Player/audioplayer.dart';
import 'package:blackhole/Theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get_it/get_it.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:logging/logging.dart';
import 'package:metadata_god/metadata_god.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:sizer/sizer.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await Hive.initFlutter('BlackHole/Database');
  } else if (Platform.isIOS) {
    await Hive.initFlutter('Database');
  } else {
    await Hive.initFlutter();
  }
  for (final box in hiveBoxes) {
    await openHiveBox(
      box['name'].toString(),
      limit: box['limit'] as bool? ?? false,
    );
  }

  if (Platform.isAndroid) {
    _requestStoragePermissions();
  }
  await startService();
  runApp(MyApp());
}

/// Requests media permissions for Android.
/// On Android 13+ (API 33), requests specific access.
Future<void> _requestStoragePermissions() async {
  final statuses = await [
    Permission.audio,
    Permission.notification,
    Permission.ignoreBatteryOptimizations,
    Permission.manageExternalStorage,
  ].request();
  final bool allGranted = statuses.values.every((status) => status.isGranted);
  if (allGranted) {
    Logger.root.info('Permissions granted.');
  } else {
    Logger.root.warning('Permissions not granted.');
  }
}

Future<void> startService() async {
  await initializeLogging();
  MetadataGod.initialize();
  final audioHandlerHelper = AudioHandlerHelper();
  final AudioPlayerHandler audioHandler =
      await audioHandlerHelper.getAudioHandler();
  GetIt.I.registerSingleton<AudioPlayerHandler>(audioHandler);
  GetIt.I.registerSingleton<MyTheme>(MyTheme());
}

Future<void> openHiveBox(String boxName, {bool limit = false}) async {
  final box = await Hive.openBox(boxName).onError((error, stackTrace) async {
    Logger.root.severe('Failed to open $boxName Box', error, stackTrace);
    final Directory dir = await getApplicationDocumentsDirectory();
    final String dirPath = dir.path;
    File dbFile = File('$dirPath/$boxName.hive');
    File lockFile = File('$dirPath/$boxName.lock');
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      dbFile = File('$dirPath/BlackHole/$boxName.hive');
      lockFile = File('$dirPath/BlackHole/$boxName.lock');
    }
    await dbFile.delete();
    await lockFile.delete();
    await Hive.openBox(boxName);
    throw 'Failed to open $boxName Box\nError: $error';
  });
  // Clear box if it grows large
  if (limit && box.length > 500) {
    box.clear();
  }
}

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();

  // ignore: unreachable_from_main
  static _MyAppState of(BuildContext context) =>
      context.findAncestorStateOfType<_MyAppState>()!;
}

class _MyAppState extends State<MyApp> {
  Locale _locale = const Locale('en', '');
  late StreamSubscription _intentDataStreamSubscription;
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  @override
  void dispose() {
    _intentDataStreamSubscription.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final String systemLangCode = Platform.localeName.substring(0, 2);
    final String? lang = Hive.box('settings').get('lang') as String?;
    if (lang == null &&
        LanguageCodes.languageCodes.values.contains(systemLangCode)) {
      _locale = Locale(systemLangCode);
    } else {
      _locale = Locale(LanguageCodes.languageCodes[lang ?? 'English'] ?? 'en');
    }

    AppTheme.currentTheme.addListener(() {
      setState(() {});
    });

    if (Platform.isAndroid || Platform.isIOS) {
      // For sharing or opening urls/text/files coming from outside the app while the app is in the memory
      _intentDataStreamSubscription =
          ReceiveSharingIntent.instance.getMediaStream().listen(
        (List<SharedMediaFile> value) {
          if (value.isNotEmpty) {
            Logger.root.info('Received intent on stream: $value');
            for (final file in value) {
              if (file.type == SharedMediaType.text ||
                  file.type == SharedMediaType.url) {
                handleSharedText(file.path, navigatorKey);
              }
              if (file.type == SharedMediaType.file) {
                if (file.path.endsWith('.json')) {
                  final List playlistNames = Hive.box('settings')
                          .get('playlistNames')
                          ?.toList() as List? ??
                      ['Favorite Songs'];
                  importFilePlaylist(
                    null,
                    playlistNames,
                    path: file.path,
                    pickFile: false,
                  ).then(
                    (value) =>
                        navigatorKey.currentState?.pushNamed('/playlists'),
                  );
                }
              }
            }
          }
        },
        onError: (err) {
          Logger.root.severe('ERROR in getMediaStream', err);
        },
      );

      // For sharing files coming from outside the app while the app is closed
      ReceiveSharingIntent.instance
          .getInitialMedia()
          .then((List<SharedMediaFile> value) {
        if (value.isNotEmpty) {
          Logger.root.info('Received Intent initially: $value');
          for (final file in value) {
            if (file.type == SharedMediaType.text ||
                file.type == SharedMediaType.url) {
              handleSharedText(file.path, navigatorKey);
            }
            if (file.type == SharedMediaType.file) {
              if (file.path.endsWith('.json')) {
                final List playlistNames = Hive.box('settings')
                        .get('playlistNames')
                        ?.toList() as List? ??
                    ['Favorite Songs'];
                importFilePlaylist(
                  null,
                  playlistNames,
                  path: file.path,
                  pickFile: false,
                ).then(
                  (value) => navigatorKey.currentState?.pushNamed('/playlists'),
                );
              }
            }
          }
          ReceiveSharingIntent.instance.reset();
        }
      }).onError((error, stackTrace) {
        Logger.root.severe('ERROR in getInitialMedia', error);
      });
    }
  }

  void setLocale(Locale value) {
    setState(() {
      _locale = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        statusBarIconBrightness: AppTheme.themeMode == ThemeMode.system
            ? MediaQuery.platformBrightnessOf(context) == Brightness.dark
                ? Brightness.light
                : Brightness.dark
            : AppTheme.themeMode == ThemeMode.dark
                ? Brightness.light
                : Brightness.dark,
        systemNavigationBarIconBrightness:
            AppTheme.themeMode == ThemeMode.system
                ? MediaQuery.platformBrightnessOf(context) == Brightness.dark
                    ? Brightness.light
                    : Brightness.dark
                : AppTheme.themeMode == ThemeMode.dark
                    ? Brightness.light
                    : Brightness.dark,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return OrientationBuilder(
            builder: (context, orientation) {
              SizerUtil.setScreenSize(constraints, orientation);
              return MaterialApp(
                title: 'BlackHole',
                restorationScopeId: 'blackhole',
                debugShowCheckedModeBanner: false,
                themeMode: AppTheme.themeMode,
                theme: AppTheme.lightTheme(
                  context: context,
                ),
                darkTheme: AppTheme.darkTheme(
                  context: context,
                ),
                locale: _locale,
                localizationsDelegates: const [
                  AppLocalizations.delegate,
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                supportedLocales: LanguageCodes.languageCodes.entries
                    .map((languageCode) => Locale(languageCode.value, ''))
                    .toList(),
                routes: namedRoutes,
                navigatorKey: navigatorKey,
                onGenerateRoute: (RouteSettings settings) {
                  if (settings.name == '/player') {
                    return PageRouteBuilder(
                      opaque: false,
                      pageBuilder: (_, __, ___) => const PlayScreen(),
                    );
                  }
                  return HandleRoute.handleRoute(settings.name);
                },
              );
            },
          );
        },
      ),
    );
  }
}
