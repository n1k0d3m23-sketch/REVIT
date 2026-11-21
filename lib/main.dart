import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _historyKey = 'car_test_history_v1';
const _gravity = 9.80665;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CarTestApp());
}

enum TestMode {
  acceleration('Przyspieszenie'),
  braking('Hamowanie'),
  coast('Wybieg'),
  handling('Zawieszenie / zakręt'),
  straight('Jazda na wprost');

  const TestMode(this.label);
  final String label;
}

class Sample {
  const Sample({
    required this.t,
    required this.speedKmh,
    required this.longitudinal,
    required this.lateral,
    required this.gyroZ,
    required this.altitude,
  });

  final double t;
  final double speedKmh;
  final double longitudinal;
  final double lateral;
  final double gyroZ;
  final double altitude;

  Map<String, dynamic> toJson() => {
        't': t,
        'speedKmh': speedKmh,
        'longitudinal': longitudinal,
        'lateral': lateral,
        'gyroZ': gyroZ,
        'altitude': altitude,
      };

  factory Sample.fromJson(Map<String, dynamic> json) => Sample(
        t: _number(json['t']),
        speedKmh: _number(json['speedKmh']),
        longitudinal: _number(json['longitudinal']),
        lateral: _number(json['lateral']),
        gyroZ: _number(json['gyroZ']),
        altitude: _number(json['altitude']),
      );
}

class TestRun {
  const TestRun({
    required this.id,
    required this.label,
    required this.mode,
    required this.date,
    required this.duration,
    required this.distance,
    required this.maxSpeed,
    required this.averageSpeed,
    required this.time0100,
    required this.time80120,
    required this.peakAccelerationG,
    required this.peakBrakingG,
    required this.peakLateralG,
    required this.vibrationRms,
    required this.ascent,
    required this.maxAltitude,
    required this.samples,
  });

  final String id;
  final String label;
  final String mode;
  final DateTime date;
  final double duration;
  final double distance;
  final double maxSpeed;
  final double averageSpeed;
  final double? time0100;
  final double? time80120;
  final double peakAccelerationG;
  final double peakBrakingG;
  final double peakLateralG;
  final double vibrationRms;
  final double ascent;
  final double maxAltitude;
  final List<Sample> samples;

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'mode': mode,
        'date': date.toIso8601String(),
        'duration': duration,
        'distance': distance,
        'maxSpeed': maxSpeed,
        'averageSpeed': averageSpeed,
        'time0100': time0100,
        'time80120': time80120,
        'peakAccelerationG': peakAccelerationG,
        'peakBrakingG': peakBrakingG,
        'peakLateralG': peakLateralG,
        'vibrationRms': vibrationRms,
        'ascent': ascent,
        'maxAltitude': maxAltitude,
        'samples': samples.map((sample) => sample.toJson()).toList(),
      };

  factory TestRun.fromJson(Map<String, dynamic> json) {
    final rawSamples = (json['samples'] as List<dynamic>? ?? []);
    return TestRun(
      id: json['id'] as String? ?? '',
      label: json['label'] as String? ?? 'Test',
      mode: json['mode'] as String? ?? '',
      date: DateTime.tryParse(json['date'] as String? ?? '') ?? DateTime.now(),
      duration: _number(json['duration']),
      distance: _number(json['distance']),
      maxSpeed: _number(json['maxSpeed']),
      averageSpeed: _number(json['averageSpeed']),
      time0100: _nullableNumber(json['time0100']),
      time80120: _nullableNumber(json['time80120']),
      peakAccelerationG: _number(json['peakAccelerationG']),
      peakBrakingG: _number(json['peakBrakingG']),
      peakLateralG: _number(json['peakLateralG']),
      vibrationRms: _number(json['vibrationRms']),
      ascent: _number(json['ascent']),
      maxAltitude: _number(json['maxAltitude']),
      samples: rawSamples
          .whereType<Map<String, dynamic>>()
          .map(Sample.fromJson)
          .toList(),
    );
  }
}

double _number(dynamic value) =>
    value is num ? value.toDouble() : 0.0;

double? _nullableNumber(dynamic value) =>
    value is num ? value.toDouble() : null;

String _fixed(double? value, [int places = 1]) =>
    value == null ? '—' : value.toStringAsFixed(places);

class CarTestApp extends StatelessWidget {
  const CarTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFF08090B);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Car Test',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: const ColorScheme.dark(
          primary: Colors.orangeAccent,
          surface: Color(0xFF15171A),
        ),
      ),
      home: const TestHome(),
    );
  }
}

class TestHome extends StatefulWidget {
  const TestHome({super.key});

  @override
  State<TestHome> createState() => _TestHomeState();
}

class _TestHomeState extends State<TestHome> {
  final _noteController = TextEditingController();

  SharedPreferences? _preferences;
  StreamSubscription<UserAccelerometerEvent>? _accelSubscription;
  StreamSubscription<GyroscopeEvent>? _gyroSubscription;
  StreamSubscription<Position>? _gpsSubscription;
  StreamSubscription<dynamic>? _barometerSubscription;
  Timer? _uiTimer;

  int _tab = 0;
  int _compareA = 0;
  int _compareB = 1;

  List<TestRun> _runs = [];
  TestRun? _lastRun;
  TestMode _mode = TestMode.acceleration;

  bool _recording = false;
  bool _calibrating = false;
  bool _gpsAvailable = false;

  DateTime? _startedAt;
  Position? _lastPosition;
  double _speedKmh = 0;
  double _altitude = 0;
  double? _pressureHpa;

  // Telefon zamocowany poziomo, górną krawędzią w kierunku jazdy:
  // oś Y = wzdłuż auta, oś X = bok auta.
  double _offsetX = 0, _offsetY = 0, _offsetZ = 0;
  double _offsetGx = 0, _offsetGy = 0, _offsetGz = 0;
  double _accelX = 0, _accelY = 0, _accelZ = 0;
  double _gyroX = 0, _gyroY = 0, _gyroZ = 0;

  final List<List<double>> _calibrationAccel = [];
  final List<List<double>> _calibrationGyro = [];
  final List<Sample> _samples = [];

  double _distance = 0;
  double _maxSpeed = 0;
  double _speedSum = 0;
  int _speedCount = 0;
  double _peakAccelerationG = 0;
  double _peakBrakingG = 0;
  double _peakLateralG = 0;
  double _vibrationSquareSum = 0;
  int _vibrationCount = 0;
  double _ascent = 0;
  double _maxAltitude = 0;
  double? _time0100;
  double? _time80120;
  double? _timeAt80;
  double? _previousSpeed;
  double? _previousElapsed;
  double _lastSampleAt = 0;

  // Wartość dBFS z opcjonalnego mostka natywnego; nie jest to skalibrowane dB SPL.
  double? _microphoneDbfs;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _startSensors();
    _startGps();
    _startOptionalChannels();

    // Odczyty czujników mogą przychodzić często. UI odświeżamy rzadziej.
    _uiTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadHistory() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_historyKey);
    if (raw == null) {
      _preferences = preferences;
      return;
    }

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final loaded = decoded
          .whereType<Map<String, dynamic>>()
          .map(TestRun.fromJson)
          .toList();
      if (!mounted) return;
      setState(() {
        _preferences = preferences;
        _runs = loaded;
      });
    } catch (_) {
      _preferences = preferences;
    }
  }

  void _startSensors() {
    _accelSubscription = userAccelerometerEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen((event) {
      final x = event.x - _offsetX;
      final y = event.y - _offsetY;
      final z = event.z - _offsetZ;

      if (_calibrating) _calibrationAccel.add([event.x, event.y, event.z]);

      const alpha = 0.22;
      final oldX = _accelX;
      final oldY = _accelY;
      final oldZ = _accelZ;

      _accelX += alpha * (x - _accelX);
      _accelY += alpha * (y - _accelY);
      _accelZ += alpha * (z - _accelZ);

      if (_recording) {
        // Przybliżony wskaźnik drgań: RMS reszty po filtrze EMA.
        final residualSquared = math.pow(x - _accelX, 2) +
            math.pow(y - _accelY, 2) +
            math.pow(z - _accelZ, 2);
        _vibrationSquareSum += residualSquared.toDouble();
        _vibrationCount++;

        _peakAccelerationG =
            math.max(_peakAccelerationG, _accelY / _gravity);
        _peakBrakingG =
            math.max(_peakBrakingG, -_accelY / _gravity);
        _peakLateralG = math.max(
          _peakLateralG,
          _accelX.abs() / _gravity,
        );

        _addSample();
      }

      // Zachowujemy zmienne używane przy diagnostyce filtra.
      // Usunięcie tych odczytów nie zmienia pomiaru.
      if (oldX.isNaN || oldY.isNaN || oldZ.isNaN) return;
    }, onError: (_) {});

    _gyroSubscription = gyroscopeEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen((event) {
      if (_calibrating) {
        _calibrationGyro.add([event.x, event.y, event.z]);
      }

      const alpha = 0.22;
      _gyroX += alpha * (event.x - _offsetGx - _gyroX);
      _gyroY += alpha * (event.y - _offsetGy - _gyroY);
      _gyroZ += alpha * (event.z - _offsetGz - _gyroZ);
    }, onError: (_) {});
  }

  Future<void> _startGps() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }

      _gpsAvailable = true;
      _gpsSubscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 0,
        ),
      ).listen(_onPosition, onError: (_) {
        _gpsAvailable = false;
      });
      if (mounted) setState(() {});
    } catch (_) {
      _gpsAvailable = false;
    }
  }

  void _onPosition(Position position) {
    if (position.accuracy > 35) return;

    final speed = math.max(0.0, position.speed * 3.6);
    final previousPosition = _lastPosition;
    final previousSpeed = _previousSpeed;
    final previousElapsed = _previousElapsed;
    final elapsed = _startedAt == null
        ? null
        : DateTime.now().difference(_startedAt!).inMicroseconds / 1e6;

    if (_recording && previousPosition != null) {
      final segment = Geolocator.distanceBetween(
        previousPosition.latitude,
        previousPosition.longitude,
        position.latitude,
        position.longitude,
      );

      // Odrzuca małe przesunięcia typowe dla szumu GPS.
      if (segment >= 2 && segment < 100) _distance += segment;
    }

    _lastPosition = position;
    _speedKmh = speed;
    _altitude = position.altitude;

    if (_recording) {
      _maxSpeed = math.max(_maxSpeed, speed);
      _speedSum += speed;
      _speedCount++;

      if (position.altitude > _maxAltitude) {
        _maxAltitude = position.altitude;
      }

      if (previousPosition != null) {
        final elevationDelta = position.altitude - previousPosition.altitude;
        if (elevationDelta > 1 && elevationDelta < 30) {
          _ascent += elevationDelta;
        }
      }

      if (elapsed != null &&
          previousSpeed != null &&
          previousElapsed != null &&
          speed > previousSpeed) {
        if (_time0100 == null &&
            previousSpeed < 100 &&
            speed >= 100) {
          _time0100 = _crossingTime(
            previousSpeed,
            speed,
            previousElapsed,
            elapsed,
            100,
          );
        }

        if (_timeAt80 == null &&
            previousSpeed < 80 &&
            speed >= 80) {
          _timeAt80 = _crossingTime(
            previousSpeed,
            speed,
            previousElapsed,
            elapsed,
            80,
          );
        }

        if (_timeAt80 != null &&
            _time80120 == null &&
            previousSpeed < 120 &&
            speed >= 120) {
          final at120 = _crossingTime(
            previousSpeed,
            speed,
            previousElapsed,
            elapsed,
            120,
          );
          _time80120 = at120 - _timeAt80!;
        }
      }
    }

    if (elapsed != null) {
      _previousSpeed = speed;
      _previousElapsed = elapsed;
    }

    if (_recording) _addSample();
    if (mounted) setState(() {});
  }

  double _crossingTime(
    double fromSpeed,
    double toSpeed,
    double fromTime,
    double toTime,
    double target,
  ) {
    final difference = toSpeed - fromSpeed;
    if (difference.abs() < 0.001) return toTime;
    final fraction = ((target - fromSpeed) / difference).clamp(0.0, 1.0);
    return fromTime + (toTime - fromTime) * fraction;
  }

  void _addSample() {
    final start = _startedAt;
    if (start == null) return;

    final now = DateTime.now();
    final elapsed = now.difference(start).inMicroseconds / 1e6;
    if (elapsed - _lastSampleAt < 0.2 || _samples.length >= 12000) return;
    _lastSampleAt = elapsed;

    _samples.add(Sample(
      t: elapsed,
      speedKmh: _speedKmh,
      longitudinal: _accelY,
      lateral: _accelX,
      gyroZ: _gyroZ,
      altitude: _altitude,
    ));
  }

  Future<void> _calibrate() async {
    if (_recording) return;

    _calibrationAccel.clear();
    _calibrationGyro.clear();
    setState(() => _calibrating = true);

    await Future<void>.delayed(const Duration(seconds: 3));
    if (!mounted) return;

    if (_calibrationAccel.isNotEmpty) {
      _offsetX = _mean(_calibrationAccel, 0);
      _offsetY = _mean(_calibrationAccel, 1);
      _offsetZ = _mean(_calibrationAccel, 2);
      _accelX = _accelY = _accelZ = 0;
    }
    if (_calibrationGyro.isNotEmpty) {
      _offsetGx = _mean(_calibrationGyro, 0);
      _offsetGy = _mean(_calibrationGyro, 1);
      _offsetGz = _mean(_calibrationGyro, 2);
      _gyroX = _gyroY = _gyroZ = 0;
    }

    setState(() => _calibrating = false);
    _message('Kalibracja zakończona.');
  }

  double _mean(List<List<double>> values, int column) {
    return values.map((row) => row[column]).reduce((a, b) => a + b) /
        values.length;
  }

  void _startRun() {
    _startedAt = DateTime.now();
    _recording = true;
    _lastPosition = null;
    _previousSpeed = null;
    _previousElapsed = null;
    _lastSampleAt = 0;
    _samples.clear();

    _distance = 0;
    _maxSpeed = _speedKmh;
    _speedSum = 0;
    _speedCount = 0;
    _peakAccelerationG = 0;
    _peakBrakingG = 0;
    _peakLateralG = 0;
    _vibrationSquareSum = 0;
    _vibrationCount = 0;
    _ascent = 0;
    _maxAltitude = _altitude;
    _time0100 = null;
    _time80120 = null;
    _timeAt80 = null;

    setState(() {});
  }

  Future<void> _stopRun() async {
    final started = _startedAt;
    if (started == null) return;

    final duration =
        DateTime.now().difference(started).inMicroseconds / 1e6;
    final label = _noteController.text.trim().isEmpty
        ? 'Test ${_runs.length + 1}'
        : _noteController.text.trim();

    final run = TestRun(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      label: label,
      mode: _mode.label,
      date: started,
      duration: duration,
      distance: _distance,
      maxSpeed: _maxSpeed,
      averageSpeed: _speedCount == 0 ? 0 : _speedSum / _speedCount,
      time0100: _time0100,
      time80120: _time80120,
      peakAccelerationG: _peakAccelerationG,
      peakBrakingG: _peakBrakingG,
      peakLateralG: _peakLateralG,
      vibrationRms: _vibrationCount == 0
          ? 0
          : math.sqrt(_vibrationSquareSum / _vibrationCount),
      ascent: _ascent,
      maxAltitude: _maxAltitude,
      samples: List<Sample>.unmodifiable(_samples),
    );

    setState(() {
      _recording = false;
      _lastRun = run;
      _runs.insert(0, run);
      _tab = 0;
    });

    await _saveHistory();
    _message('Zapisano: ${run.label}');
  }

  Future<void> _saveHistory() async {
    _preferences ??= await SharedPreferences.getInstance();
    await _preferences!.setString(
      _historyKey,
      jsonEncode(_runs.map((run) => run.toJson()).toList()),
    );
  }

  void _startOptionalChannels() {
    // Opcjonalny mostek natywny opisany pod kodem. Bez niego stream
    // zgłosi błąd, który jest obsługiwany bez przerywania aplikacji.
    const pressureChannel = EventChannel('car_test/barometer');
    _barometerSubscription = pressureChannel
        .receiveBroadcastStream()
        .listen((value) {
      if (value is num && mounted) {
        setState(() => _pressureHpa = value.toDouble());
      }
    }, onError: (_) {});

    const microphoneChannel = EventChannel('car_test/microphone_dbfs');
    microphoneChannel.receiveBroadcastStream().listen((value) {
      if (value is num && mounted) {
        setState(() => _microphoneDbfs = value.toDouble());
      }
    }, onError: (_) {});
  }

  Future<void> _exportJson() async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/car_test_history.json');
    await file.writeAsString(
      const JsonEncoder.withIndent('  ')
          .convert(_runs.map((run) => run.toJson()).toList()),
    );
    _message('JSON zapisany: ${file.path}');
  }

  Future<void> _exportCsv() async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/car_test_samples.csv');
    final output = StringBuffer(
      'test,date,mode,t_s,speed_kmh,longitudinal_mps2,'
      'lateral_mps2,gyro_z_rad_s,altitude_m\n',
    );

    for (final run in _runs) {
      for (final sample in run.samples) {
        output.writeln([
          _csv(run.label),
          run.date.toIso8601String(),
          _csv(run.mode),
          sample.t,
          sample.speedKmh,
          sample.longitudinal,
          sample.lateral,
          sample.gyroZ,
          sample.altitude,
        ].join(','));
      }
    }

    await file.writeAsString(output.toString());
    _message('CSV zapisany: ${file.path}');
  }

  String _csv(String text) => '"${text.replaceAll('"', '""')}"';

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
    );
  }

  @override
  void dispose() {
    _noteController.dispose();
    _accelSubscription?.cancel();
    _gyroSubscription?.cancel();
    _gpsSubscription?.cancel();
    _barometerSubscription?.cancel();
    _uiTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'CAR TEST',
          style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2),
        ),
        backgroundColor: const Color(0xFF08090B),
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          _testScreen(),
          _historyScreen(),
          _comparisonScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.speed),
            label: 'Test',
          ),
          NavigationDestination(
            icon: Icon(Icons.history),
            label: 'Historia',
          ),
          NavigationDestination(
            icon: Icon(Icons.compare_arrows),
            label: 'Porównanie',
          ),
        ],
      ),
    );
  }
  Widget _testScreen() {
    final elapsed = _startedAt == null
        ? 0.0
        : DateTime.now().difference(_startedAt!).inMicroseconds / 1e6;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        DropdownButtonFormField<TestMode>(
          value: _mode,
          decoration: const InputDecoration(
            labelText: 'Tryb testu',
            border: OutlineInputBorder(),
          ),
          items: TestMode.values
              .map((mode) => DropdownMenuItem(
                    value: mode,
                    child: Text(mode.label),
                  ))
              .toList(),
          onChanged: _recording
              ? null
              : (value) {
                  if (value != null) setState(() => _mode = value);
                },
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _recording || _calibrating ? null : _calibrate,
                icon: const Icon(Icons.my_location),
                label: Text(
                  _calibrating ? 'KALIBRACJA…' : 'KALIBRUJ NA POSTOJU',
                ),
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              _gpsAvailable ? Icons.gps_fixed : Icons.gps_off,
              color: _gpsAvailable ? Colors.lightGreenAccent : Colors.orange,
            ),
          ],
        ),
        const SizedBox(height: 18),
        Card(
          color: const Color(0xFF15171A),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 18),
            child: Column(
              children: [
                Text(
                  _speedKmh.toStringAsFixed(0),
                  style: const TextStyle(
                    fontSize: 76,
                    height: 1,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const Text(
                  'km/h GPS',
                  style: TextStyle(color: Colors.white60, letterSpacing: 2),
                ),
                const SizedBox(height: 18),
                Wrap(
                  alignment: WrapAlignment.spaceEvenly,
                  spacing: 18,
                  runSpacing: 10,
                  children: [
                    _smallValue('CZAS', '${elapsed.toStringAsFixed(1)} s'),
                    _smallValue('DYSTANS', '${_distance.toStringAsFixed(0)} m'),
                    _smallValue('WYSOKOŚĆ', '${_altitude.toStringAsFixed(0)} m'),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _metricCard(
                'Wzdłuż',
                '${(_accelY / _gravity).toStringAsFixed(2)} G',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _metricCard(
                'Bocznie',
                '${(_accelX / _gravity).toStringAsFixed(2)} G',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _metricCard(
                'Żyroskop Z',
                '${_gyroZ.toStringAsFixed(2)} rad/s',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _metricCard(
                'Ciśnienie',
                _pressureHpa == null
                    ? 'brak czujnika'
                    : '${_pressureHpa!.toStringAsFixed(1)} hPa',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _metricCard(
                'Mikrofon',
                _microphoneDbfs == null
                    ? 'wyłączony'
                    : '${_microphoneDbfs!.toStringAsFixed(1)} dBFS',
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _noteController,
          enabled: !_recording,
          decoration: const InputDecoration(
            labelText: 'Etykieta / notatka, np. po wymianie opon',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 64,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _recording ? Colors.redAccent : Colors.orange,
              foregroundColor: Colors.black,
            ),
            onPressed: _recording ? _stopRun : _startRun,
            child: Text(
              _recording ? 'STOP — ZAPISZ TEST' : 'START',
              style: const TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.4,
              ),
            ),
          ),
        ),
        if (_lastRun != null) ...[
          const SizedBox(height: 18),
          _runCard(_lastRun!),
        ],
        const SizedBox(height: 12),
        const Text(
          'Kalibrację wykonuj na postoju. Telefon musi być zamocowany '
          'poziomo i skierowany przodem auta. Wyniki GPS zależą od jakości '
          'odbiornika, pogody i warunków trasy.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ],
    );
  }
  Widget _smallValue(String label, String value) => Column(
        children: [
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
          const SizedBox(height: 3),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      );
  Widget _metricCard(String title, String value) => Card(
        color: const Color(0xFF15171A),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Text(title, style: const TextStyle(color: Colors.white54)),
              const SizedBox(height: 5),
              Text(
                value,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      );
  Widget _historyScreen() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _runs.isEmpty ? null : _exportJson,
              icon: const Icon(Icons.data_object),
              label: const Text('Eksport JSON'),
            ),
            OutlinedButton.icon(
              onPressed: _runs.isEmpty ? null : _exportCsv,
              icon: const Icon(Icons.table_view),
              label: const Text('Eksport CSV'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (_runs.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 48),
            child: Center(child: Text('Brak zapisanych testów')),
          )
        else
          ..._runs.map(
            (run) => InkWell(
              onTap: () => showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  title: Text(run.label),
                  content: SingleChildScrollView(child: _runCard(run)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('ZAMKNIJ'),
                    ),
                  ],
                ),
              ),
              child: _runCard(run),
            ),
          ),
      ],
    );
  }
  Widget _runCard(TestRun run) {
    return Card(
      color: const Color(0xFF15171A),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              run.label,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              '${run.mode} • ${run.date.toLocal()}',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const Divider(),
            _detailRow('0–100 km/h', '${_fixed(run.time0100)} s'),
            _detailRow('80–120 km/h', '${_fixed(run.time80120)} s'),
            _detailRow('Prędkość maksymalna', '${_fixed(run.maxSpeed)} km/h'),
            _detailRow('Prędkość średnia', '${_fixed(run.averageSpeed)} km/h'),
            _detailRow('Dystans', '${_fixed(run.distance, 0)} m'),
            _detailRow('Szczyt hamowania', '${_fixed(run.peakBrakingG, 2)} G'),
            _detailRow('Szczyt boczny', '${_fixed(run.peakLateralG, 2)} G'),
            _detailRow('Przewyższenie', '${_fixed(run.ascent, 0)} m'),
          ],
        ),
      ),
    );
  }
  Widget _detailRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(color: Colors.white60)),
            Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
      );
  Widget _comparisonScreen() {
    if (_runs.length < 2) {
      return const Center(
        child: Text('Zapisz co najmniej dwa testy, aby je porównać.'),
      );
    }
    _compareA = _compareA.clamp(0, _runs.length - 1);
    _compareB = _compareB.clamp(0, _runs.length - 1);
    if (_compareA == _compareB) {
      _compareB = (_compareA + 1) % _runs.length;
    }
    final a = _runs[_compareA];
    final b = _runs[_compareB];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _runSelector('Test A', _compareA, (value) {
          if (value != null) setState(() => _compareA = value);
        }),
        const SizedBox(height: 10),
        _runSelector('Test B', _compareB, (value) {
          if (value != null) setState(() => _compareB = value);
        }),
        const SizedBox(height: 16),
        Card(
          color: const Color(0xFF15171A),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _compareRow('0–100 km/h', a.time0100, b.time0100, 's'),
                _compareRow('80–120 km/h', a.time80120, b.time80120, 's'),
   
[Truncated on import]_
