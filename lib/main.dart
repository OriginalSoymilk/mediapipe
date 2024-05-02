import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_ml_kit/google_ml_kit.dart';
import 'dart:typed_data';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: FutureBuilder(
        future: availableCameras(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return CameraScreen(
                cameras: snapshot.data as List<CameraDescription>);
          } else {
            return const CircularProgressIndicator();
          }
        },
      ),
    );
  }
}

class CameraScreen extends StatefulWidget {
  final List<CameraDescription> cameras;

  const CameraScreen({Key? key, required this.cameras}) : super(key: key);

  @override
  CameraScreenState createState() => CameraScreenState();
}

class CameraScreenState extends State<CameraScreen> {
  late CameraController _cameraController;
  bool isDetecting = false;
  late PoseDetector _poseDetector;
  List<Pose> poses = [];
  bool isFrontCamera = false;
  double _fpsAverage = 0.0;
  int _fpsCounter = 0;
  DateTime? _lastFrameTime;
  int frameCounter = 0;
  int correctCount = 0;
  bool isPassed = false;
  final int framesToSendHttpRequest = 5;
  // 定义模型路径列表
  final List<String> modelPaths = ['/predict/init', '/predict/warrior'];
  // 用于保存当前选择的模型路径
  String selectedModelPath = '/predict/init'; // 默认选择第一个模型
  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _poseDetector = PoseDetector(
      options: PoseDetectorOptions(
        model: PoseDetectionModel.base,
        mode: PoseDetectionMode.stream,
      ),
    );
  }

  Future<void> _initializeCamera() async {
    final CameraDescription selectedCamera = isFrontCamera
        ? widget.cameras.firstWhere(
            (camera) => camera.lensDirection == CameraLensDirection.front)
        : widget.cameras.firstWhere(
            (camera) => camera.lensDirection == CameraLensDirection.back);

    _cameraController =
        CameraController(selectedCamera, ResolutionPreset.high);
    await _cameraController.initialize();
    if (mounted) {
      setState(() {});
      _cameraController.startImageStream((CameraImage image) {
        if (!isDetecting) {
          isDetecting = true;
          _detectPose(image, isFrontCamera);
        }
      });
    }
  }

  void _toggleCamera() {
    setState(() {
      isFrontCamera = !isFrontCamera;
      _initializeCamera();
    });
  }

  Future<void> _detectPose(CameraImage image, bool isFrontCamera) async {
    final InputImageRotation rotation = isFrontCamera
        ? InputImageRotation.rotation270deg // 前置摄像头
        : InputImageRotation.rotation90deg; // 后置摄像头

    final InputImage inputImage = InputImage.fromBytes(
      bytes: _concatenatePlanes(image.planes),
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: image.planes[0].bytesPerRow,
      ),
    );

    try {
      final List<Pose> detectedPoses =
          await _poseDetector.processImage(inputImage);

      // 在_detectPose方法中的try块中
      // 将姿势坐标转换为JSON
      final List<Map<String, dynamic>> jsonPoses = detectedPoses.map((pose) {
        final Map<String, dynamic> poseMap = {};
        for (var landmark in pose.landmarks.values) {
          final Map<String, dynamic> landmarkMap = {
            "x": landmark.x.toStringAsFixed(2),
            "y": landmark.y.toStringAsFixed(2),
            "z": 0.0,
            "v": landmark.likelihood.toStringAsFixed(2)
          };
            poseMap[landmark.type.toString()] = landmarkMap;
        }
        return poseMap;
      }).toList();

      print(jsonPoses);


      //setState(() {
        //print("num3: $num3");

        //num3++;
      //});
      setState(() {
        poses = detectedPoses;
      });
      // 发送 HTTP 请求到服务器
      frameCounter++;
      if (frameCounter == framesToSendHttpRequest) {
        // 发送 HTTP 请求到服务器
        _sendHttpRequest(jsonPoses);
        frameCounter = 0; // 重置帧计数器
      }
    } catch (e) {
      print("Error detecting pose: $e");
    } finally {
      isDetecting = false;
    }
  }

  String result = '';
  String prob = '';
  Future<void> _sendHttpRequest(List<Map<String, dynamic>> jsonPoses) async {
    try {
      final response = await http.post(
        Uri.parse('https://mp-hdkf.onrender.com$selectedModelPath'),
        body: jsonEncode({'jsonPoses': jsonPoses}),
        headers: {'Content-Type': 'application/json'},
      );

      setState(() {
        Map<String, dynamic> responseData = jsonDecode(response.body);
        result = responseData['body_language_class'].toString();
        prob = responseData['body_language_prob'].toString();
        print(result);
        print(prob);

        if (result == 'correct') {
          correctCount++;
          if (correctCount >= 3) {
            isPassed = true;
            _speak('通過');
          }
        } else {
          correctCount = 0;
          isPassed = false;
        }
      });
    } catch (e) {
      print("Error sending HTTP request: $e");
    }
  }

  Uint8List _concatenatePlanes(List<Plane> planes) {
    List<int> allBytes = [];
    for (Plane plane in planes) {
      allBytes.addAll(plane.bytes);
    }
    return Uint8List.fromList(allBytes);
  }
  Future<void> _speak(String text) async {
    FlutterTts flutterTts = FlutterTts();
    await flutterTts.speak(text);
  }
  String _getFps() {
    DateTime currentTime = DateTime.now();
    double currentFps = _lastFrameTime != null
        ? 1000 / currentTime.difference(_lastFrameTime!).inMilliseconds
        : 0;

    _fpsAverage = (_fpsAverage * _fpsCounter + currentFps) / (_fpsCounter + 1);
    _fpsCounter++;

    if (_fpsCounter > 100) {
      _fpsCounter = 0;
      _fpsAverage = currentFps;
    }

    _lastFrameTime = currentTime;

    return _fpsAverage.toStringAsFixed(1);
  }

  @override
  void dispose() {
    _cameraController.dispose();
    _poseDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_cameraController.value.isInitialized) {
      return Container();
    }

    final size = MediaQuery.of(context).size;

    return Scaffold(
      body: FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: _cameraController.value.previewSize!.height,
          height: _cameraController.value.previewSize!.width,
          child: Stack(
            children: [
              CameraPreview(_cameraController),
              CustomPaint(
                painter: PosePainter(poses, isFrontCamera),
              ),
              Positioned(
                top: 10.0,
                left: 10.0,
                child: Text(
                  'FPS: ${_getFps()}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16.0,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _toggleCamera,
        child: const Icon(Icons.switch_camera),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.startDocked,
      persistentFooterButtons: [
        DropdownButton<String>(
          value: selectedModelPath,
          onChanged: (String? newValue) {
            if (newValue != null) {
              setState(() {
                selectedModelPath = newValue;
              });
            }
          },
          items: modelPaths.map<DropdownMenuItem<String>>((String value) {
            return DropdownMenuItem<String>(
              value: value,
              child: Text(value),
            );
          }).toList(),
        ),
        // 显示结果和通过/未通过文本
        Text('$result $prob'),
        Text(isPassed ? '通過' : '未通過'),
      ],

    );
  }
}

class PosePainter extends CustomPainter {
  final List<Pose> poses;
  final bool isFrontCamera;

  PosePainter(this.poses, this.isFrontCamera);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red
      ..strokeWidth = 5;

    for (var pose in poses) {
      for (var landmark in pose.landmarks.values) {
        double x = landmark.x;
        double y = landmark.y;

        // 如果是前置摄像头，进行垂直翻转
        if (isFrontCamera) {
          x = size.width + 480 - x;
        }

        canvas.drawCircle(
          Offset(x, y),
          5.0,
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) {
    return true;
  }
}
