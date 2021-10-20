import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

const debug = true;

class TestingDownload extends StatefulWidget with WidgetsBindingObserver {
  final TargetPlatform platform;

  ///This code is for me to send the title and link data from firebase to this page
  final String title;
  final String url;

  const TestingDownload({Key key, this.platform, this.url, this.title})
      : super(key: key);
  @override
  _TestingDownloadState createState() => _TestingDownloadState();
}

class _TestingDownloadState extends State<TestingDownload> {
  List<_TaskInfo> _tasks;
  List<_ItemHolder> _items;
  bool _isLoading;
  bool _permissionReady;
  String _localPath;
  ReceivePort _port = ReceivePort();

  @override
  void initState() {
    super.initState();

    _bindBackgroundIsolate();

    FlutterDownloader.registerCallback(downloadCallback);

    _isLoading = true;
    _permissionReady = false;

    _prepare();
  }

  @override
  void dispose() {
    _unbindBackgroundIsolate();
    super.dispose();
  }

  void _bindBackgroundIsolate() {
    bool isSuccess = IsolateNameServer.registerPortWithName(
        _port.sendPort, 'downloader_send_port');
    if (!isSuccess) {
      _unbindBackgroundIsolate();
      _bindBackgroundIsolate();
      return;
    }
    _port.listen((dynamic data) {
      if (debug) {
        print('UI Isolate Callback: $data');
      }
      String id = data[0];
      DownloadTaskStatus status = data[1];
      int progress = data[2];

      final task = _tasks?.firstWhere((task) => task.taskId == id);
      if (task != null) {
        setState(() {
          task.status = status;
          task.progress = progress;
        });
      }
    });
  }

  void _unbindBackgroundIsolate() {
    IsolateNameServer.removePortNameMapping('downloader_send_port');
  }

  static void downloadCallback(
      String id, DownloadTaskStatus status, int progress) {
    if (debug) {
      print(
          'Background Isolate Callback: task ($id) is in status ($status) and process ($progress)');
    }
    final SendPort send =
        IsolateNameServer.lookupPortByName('downloader_send_port');
    send.send([id, status, progress]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Color(0xFFEB2828),
        title: Text(
          ///This text you can change to your file name
          "Download ${widget.title}",
          maxLines: 1,
          softWrap: true,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'Nunito',
            fontSize: 22,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: Builder(
          builder: (context) => _isLoading
              ? new Center(
                  child: new CircularProgressIndicator(),
                )
              : _permissionReady
                  ? _buildDownloadList()
                  : _buildNoPermissionWarning()),
    );
  }

  Widget _buildNoPermissionWarning() => Container(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: Text(
                  'Please grant accessing storage permission to continue',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.blueGrey, fontSize: 18.0),
                ),
              ),
              SizedBox(
                height: 32.0,
              ),
              FlatButton(
                  onPressed: () {
                    _checkPermission().then((hasGranted) {
                      setState(() {
                        _permissionReady = hasGranted;
                      });
                    });
                  },
                  child: Text(
                    'Retry',
                    style: TextStyle(
                        color: Colors.blue,
                        fontWeight: FontWeight.bold,
                        fontSize: 20.0),
                  ))
            ],
          ),
        ),
      );

  Widget _buildDownloadList() => Container(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 16.0),
          children: _items
              .map((item) => item.task == null
                  ? _buildListSection(item.name)
                  : DownloadItem(
                      data: item,
                      onItemClick: (task) {
                        _openDownloadedFile(task).then((success) {
                          if (!success) {
                            Scaffold.of(context).showSnackBar(SnackBar(
                                content: Text('Cannot open this file')));
                          }
                        });
                      },
                      onAtionClick: (task) {
                        if (task.status == DownloadTaskStatus.undefined) {
                          Platform.isAndroid
                              ? _requestDownloadAndroid(task)
                              : _requestDownload(task);
                        } else if (task.status == DownloadTaskStatus.running) {
                          _pauseDownload(task);
                        } else if (task.status == DownloadTaskStatus.paused) {
                          _resumeDownload(task);
                        } else if (task.status == DownloadTaskStatus.complete) {
                          _delete(task);
                        } else if (task.status == DownloadTaskStatus.failed) {
                          _retryDownload(task);
                        }
                      },
                    ))
              .toList(),
        ),
      );

  Widget _buildListSection(String title) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: Text(
          title,
          style: TextStyle(
              fontWeight: FontWeight.bold, color: Colors.black, fontSize: 18.0),
        ),
      );

  void _requestDownloadAndroid(_TaskInfo task) async {
    final externalDir = await getExternalStorageDirectory();

    task.taskId = await FlutterDownloader.enqueue(

        ///This url is where you get your url from firebase
        url: widget.url,
        //headers: {"auth": "test_for_sql_encoding"},
        savedDir: externalDir.path,

        ///The file name you can change to your own file name
        fileName: '${widget.title}.pdf',
        showNotification: true,
        openFileFromNotification: true);
  }

  void _requestDownload(_TaskInfo task) async {
    task.taskId = await FlutterDownloader.enqueue(
        url: task.link,
        //headers: {"auth": "test_for_sql_encoding"},
        savedDir: _localPath,
        showNotification: true,
        openFileFromNotification: true);
  }

  void _pauseDownload(_TaskInfo task) async {
    await FlutterDownloader.pause(taskId: task.taskId);
  }

  void _resumeDownload(_TaskInfo task) async {
    String newTaskId = await FlutterDownloader.resume(taskId: task.taskId);
    task.taskId = newTaskId;
  }

  void _retryDownload(_TaskInfo task) async {
    String newTaskId = await FlutterDownloader.retry(taskId: task.taskId);
    task.taskId = newTaskId;
  }

  Future<bool> _openDownloadedFile(_TaskInfo task) {
    return FlutterDownloader.open(taskId: task.taskId);
  }

  void _delete(_TaskInfo task) async {
    await FlutterDownloader.remove(
        taskId: task.taskId, shouldDeleteContent: true);
    await _prepare();
    setState(() {});
  }

  Future<bool> _checkPermission() async {
    if (widget.platform == TargetPlatform.android) {
      final status = await Permission.storage.status;
      if (status != PermissionStatus.granted) {
        final result = await Permission.storage.request();
        if (result == PermissionStatus.granted) {
          return true;
        }
      } else {
        return true;
      }
    } else {
      return true;
    }
    return false;
  }

  Future<Null> _prepare() async {
    final _documents = [
      {
        ///Here you can change the title and the url(firebase)
        'name': widget.title,
        'link': widget.url,
      },
    ];

    final tasks = await FlutterDownloader.loadTasks();

    int count = 0;
    _tasks = [];
    _items = [];

    _tasks.addAll(_documents.map((document) =>
        _TaskInfo(name: document['name'], link: document['link'])));

    for (int i = count; i < _tasks.length; i++) {
      _items.add(_ItemHolder(name: _tasks[i].name, task: _tasks[i]));
      count++;
    }

    tasks?.forEach((task) {
      for (_TaskInfo info in _tasks) {
        if (info.link == task.url) {
          info.taskId = task.taskId;
          info.status = task.status;
          info.progress = task.progress;
        }
      }
    });

    _permissionReady = await _checkPermission();

    _localPath = (await _findLocalPath()) + Platform.pathSeparator + 'Download';

    final savedDir = Directory(_localPath);
    bool hasExisted = await savedDir.exists();
    if (!hasExisted) {
      savedDir.create();
    }

    setState(() {
      _isLoading = false;
    });
  }

  Future<String> _findLocalPath() async {
    final directory = widget.platform == TargetPlatform.android
        ? await getExternalStorageDirectory()
        : await getApplicationDocumentsDirectory();
    //print('${directory.path} hello');
    return directory.path;
  }
}

class DownloadItem extends StatelessWidget {
  final _ItemHolder data;
  final Function(_TaskInfo) onItemClick;
  final Function(_TaskInfo) onAtionClick;

  DownloadItem({this.data, this.onItemClick, this.onAtionClick});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 16.0, right: 8.0),
      child: InkWell(
        onTap: data.task.status == DownloadTaskStatus.complete ? null : null,
        child: Stack(
          children: <Widget>[
            Container(
              width: double.infinity,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  SizedBox(height: 200),
                  Container(
                    child: Text(
                      data.name,
                      maxLines: 3,
                      softWrap: true,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'Nunito',
                      ),
                    ),
                  ),
                  SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.only(left: 8.0),
                    child: _buildActionForTask(data.task),
                  ),
                ],
              ),
            ),
            data.task.status == DownloadTaskStatus.running ||
                    data.task.status == DownloadTaskStatus.paused
                ? Padding(
                    padding: const EdgeInsets.all(30.0),
                    child: Positioned(
                      left: 0.0,
                      right: 0.0,
                      bottom: 0.0,
                      child: LinearProgressIndicator(
                        backgroundColor: Colors.grey,
                        value: data.task.progress / 100,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Color(0xFFEB2828),
                        ),
                      ),
                    ),
                  )
                : Container()
          ].where((child) => child != null).toList(),
        ),
      ),
    );
  }

  Widget _buildActionForTask(_TaskInfo task) {
    if (task.status == DownloadTaskStatus.undefined) {
      return RaisedButton(
          elevation: 4.0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          color: Color(0xFFEB2828),
          child: Container(
            width: 140,
            height: 44,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: <Widget>[
                Icon(
                  Icons.file_download,
                  color: Colors.white,
                ),
                SizedBox(
                  width: 20,
                ),
                Text(
                  'Download',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 17,
                  ),
                ),
              ],
            ),
          ),
          onPressed: () {
            print('Download');
            onAtionClick(task);
          });
    } else if (task.status == DownloadTaskStatus.running) {
      return RaisedButton(
        elevation: 4.0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        color: Color(0xFFEB2828),
        onPressed: () {
          onAtionClick(task);
        },
        child: Container(
          width: 140,
          height: 54,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.pause,
                color: Colors.white,
              ),
              SizedBox(
                width: 36,
              ),
              Text(
                'Pause',
                style: TextStyle(
                  fontFamily: 'Nunito',
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 17,
                ),
              ),
            ],
          ),
        ),
      );
    } else if (task.status == DownloadTaskStatus.paused) {
      return RaisedButton(
        elevation: 4.0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        color: Color(0xFFEB2828),
        onPressed: () {
          onAtionClick(task);
        },
        child: Container(
          width: 140,
          height: 54,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.play_arrow,
                color: Colors.white,
              ),
              SizedBox(
                width: 36,
              ),
              Text(
                'Play',
                style: TextStyle(
                  fontFamily: 'Nunito',
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 17,
                ),
              ),
            ],
          ),
        ),
      );
    } else if (task.status == DownloadTaskStatus.complete) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          RaisedButton(
            elevation: 4.0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            color: Colors.white,
            onPressed: () {
              onItemClick(data.task);
              print('open pdf');
            },
            child: Container(
              width: 140,
              height: 54,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.folder_open,
                    color: Color(0xFFEB2828),
                  ),
                  SizedBox(
                    width: 36,
                  ),
                  Text(
                    'Open',
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      color: Color(0xFFEB2828),
                      fontWeight: FontWeight.w600,
                      fontSize: 17,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: 100),
          RaisedButton(
            elevation: 4.0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            color: Color(0xFFEB2828),
            onPressed: () {
              onAtionClick(task);
            },
            child: Container(
              width: 140,
              height: 54,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.delete,
                    color: Colors.white,
                  ),
                  SizedBox(
                    width: 36,
                  ),
                  Text(
                    'Delete',
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 17,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    } else if (task.status == DownloadTaskStatus.canceled) {
      return Text('Canceled', style: TextStyle(color: Colors.red));
    } else if (task.status == DownloadTaskStatus.failed) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text('Failed', style: TextStyle(color: Colors.red)),
          RawMaterialButton(
            onPressed: () {
              onAtionClick(task);
            },
            child: Icon(
              Icons.refresh,
              color: Colors.green,
            ),
            shape: CircleBorder(),
            constraints: BoxConstraints(minHeight: 32.0, minWidth: 32.0),
          )
        ],
      );
    } else {
      return null;
    }
  }
}

class _TaskInfo {
  final String name;
  final String link;

  String taskId;
  int progress = 0;
  DownloadTaskStatus status = DownloadTaskStatus.undefined;

  _TaskInfo({this.name, this.link});
}

class _ItemHolder {
  final String name;
  final _TaskInfo task;

  _ItemHolder({this.name, this.task});
}
