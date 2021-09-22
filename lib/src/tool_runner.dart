// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dartdoc.tool_runner;

import 'dart:io' show Process, ProcessException;

import 'package:analyzer/file_system/file_system.dart';
import 'package:dartdoc/src/dartdoc_options.dart';
import 'package:dartdoc/src/io_utils.dart';
import 'package:dartdoc/src/tool_definition.dart';
import 'package:path/path.dart' as p;

typedef ToolErrorCallback = void Function(String message);
typedef FakeResultCallback = String Function(String tool,
    {List<String> args, String content});

class ToolTempFileTracker {
  final ResourceProvider resourceProvider;
  final Folder temporaryDirectory;

  ToolTempFileTracker._(this.resourceProvider)
      : temporaryDirectory =
            resourceProvider.createSystemTemp('dartdoc_tools_');

  static final Map<ResourceProvider, ToolTempFileTracker> _instances = {};

  static ToolTempFileTracker instanceFor(ResourceProvider resourceProvider) =>
      _instances.putIfAbsent(
          resourceProvider, () => ToolTempFileTracker._(resourceProvider));

  int _temporaryFileCount = 0;

  File createTemporaryFile() {
    _temporaryFileCount++;
    // TODO(srawlins): Assume [temporaryDirectory]'s path is always absolute.
    var tempFile = resourceProvider.getFile(resourceProvider.pathContext.join(
        resourceProvider.pathContext.absolute(temporaryDirectory.path),
        'input_$_temporaryFileCount'));
    tempFile.writeAsStringSync('');
    return tempFile;
  }

  /// Call once no more files are to be created.
  void dispose() {
    if (temporaryDirectory.exists) {
      temporaryDirectory.delete();
    }
  }
}

/// A helper class for running external tools.
class ToolRunner {
  /// Creates a new ToolRunner.
  ///
  /// Takes a [toolConfiguration] that describes all of the available tools.
  /// An optional `errorCallback` will be called for each error message
  /// generated by the tool.
  ToolRunner(this.toolConfiguration);

  /// Set a ceiling on how many tool instances can be in progress at once,
  /// limiting both parallelization and the number of open temporary files.
  static final TaskQueue<String> _toolTracker = TaskQueue<String>();

  Future<void> wait() => _toolTracker.tasksComplete;

  final ToolConfiguration toolConfiguration;

  Future<void> _runSetup(
      String name,
      ToolDefinition tool,
      Map<String, String> environment,
      ToolErrorCallback toolErrorCallback) async {
    var isDartSetup = ToolDefinition.isDartExecutable(tool.setupCommand[0]);
    var args = tool.setupCommand.toList();
    String commandPath;

    if (isDartSetup) {
      commandPath = resourceProvider.resolvedExecutable;
    } else {
      commandPath = args.removeAt(0);
    }
    // We do not use the stdout of the setup process.
    await _runProcess(name, '', commandPath, args, environment,
        toolErrorCallback: toolErrorCallback);
    tool.setupComplete = true;
  }

  /// Runs the tool with [Process.run], awaiting the exit code, and returning
  /// the stdout.
  ///
  /// If the process's exit code is not 0, or if a [ProcessException] is thrown,
  /// calls [toolErrorCallback] with a detailed error message, and returns `''`.
  Future<String> _runProcess(String name, String content, String commandPath,
      List<String> args, Map<String, String> environment,
      {required ToolErrorCallback toolErrorCallback}) async {
    String commandString() => ([commandPath] + args).join(' ');
    try {
      var result =
          await Process.run(commandPath, args, environment: environment);
      if (result.exitCode != 0) {
        toolErrorCallback('Tool "$name" returned non-zero exit code '
            '(${result.exitCode}) when run as "${commandString()}" from '
            '${pathContext.current}\n'
            'Input to $name was:\n'
            '$content\n'
            'Stderr output was:\n${result.stderr}\n');
        return '';
      } else {
        return result.stdout;
      }
    } on ProcessException catch (exception) {
      toolErrorCallback('Failed to run tool "$name" as '
          '"${commandString()}": $exception\n'
          'Input to $name was:\n'
          '$content');
      return '';
    }
  }

  /// Run a tool.
  ///
  /// The name of the tool is the first argument in the [args]. The content to
  /// be sent to to the tool is given in the optional [content]. The stdout of
  /// the tool is returned.
  Future<String> run(List<String> args,
      {required String content,
      required ToolErrorCallback toolErrorCallback,
      Map<String, String> environment = const {}}) async {
    assert(args.isNotEmpty);
    return _toolTracker.add(() {
      return _run(args,
          toolErrorCallback: toolErrorCallback,
          content: content,
          environment: environment);
    });
  }

  Future<String> _run(List<String> args,
      {required ToolErrorCallback toolErrorCallback,
      String content = '',
      required Map<String, String> environment}) async {
    assert(args.isNotEmpty);
    var toolName = args.removeAt(0);
    if (!toolConfiguration.tools.containsKey(toolName)) {
      toolErrorCallback(
          'Unable to find definition for tool "$toolName" in tool map. '
          'Did you add it to dartdoc_options.yaml?');
      return '';
    }
    var toolDefinition = toolConfiguration.tools[toolName];
    var toolArgs = toolDefinition!.command;

    // Substitute the temp filename for the "$INPUT" token, and all of the other
    // environment variables. Variables are allowed to either be in $(VAR) form,
    // or $VAR form.
    var envWithInput = {
      'INPUT': _tmpFileWithContent(content),
      'TOOL_COMMAND': toolArgs[0],
      ...environment,
    };
    if (toolDefinition is DartToolDefinition) {
      // Put the original command path into the environment, because when it
      // runs as a snapshot, Platform.script (inside the tool script) refers to
      // the snapshot, and not the original script.  This way at least, the
      // script writer can use this instead of Platform.script if they want to
      // find out where their script was coming from as an absolute path on the
      // filesystem.
      envWithInput['DART_SNAPSHOT_CACHE'] = pathContext.absolute(
          SnapshotCache.instanceFor(resourceProvider).snapshotCache.path);
      if (toolDefinition.setupCommand.isNotEmpty) {
        envWithInput['DART_SETUP_COMMAND'] = toolDefinition.setupCommand[0];
      }
    }

    var argsWithInput = [
      ...toolArgs,
      ..._substituteInArgs(args, envWithInput),
    ];

    if (toolDefinition.setupCommand.isNotEmpty &&
        !toolDefinition.setupComplete) {
      await _runSetup(
          toolName, toolDefinition, envWithInput, toolErrorCallback);
    }

    var toolStateForArgs = await toolDefinition.toolStateForArgs(
        toolName, argsWithInput,
        toolErrorCallback: toolErrorCallback);
    var commandPath = toolStateForArgs.commandPath;
    argsWithInput = toolStateForArgs.args;
    var callCompleter = toolStateForArgs.onProcessComplete;
    var stdout = _runProcess(
        toolName, content, commandPath, argsWithInput, envWithInput,
        toolErrorCallback: toolErrorCallback);

    if (callCompleter == null) {
      return stdout;
    } else {
      return stdout.whenComplete(callCompleter);
    }
  }

  /// Returns the path to the temp file after [content] is written to it.
  String _tmpFileWithContent(String content) {
    // Ideally, we would just be able to send the input text into stdin, but
    // there's no way to do that synchronously, and converting dartdoc to an
    // async model of execution is a huge amount of work. Using dart:cli's
    // waitFor feels like a hack (and requires a similar amount of work anyhow
    // to fix order of execution issues). So, instead, we have the tool take a
    // filename as part of its arguments, and write the input to a temporary
    // file before running the tool synchronously.

    // Write the content to a temp file.
    var tmpFile =
        ToolTempFileTracker.instanceFor(resourceProvider).createTemporaryFile();
    tmpFile.writeAsStringSync(content);
    return pathContext.absolute(tmpFile.path);
  }

  // TODO(srawlins): Unit tests.
  List<String> _substituteInArgs(
      List<String> args, Map<String, String> envWithInput) {
    var substitutions = envWithInput.map<RegExp, String>((key, value) {
      var escapedKey = RegExp.escape(key);
      return MapEntry(RegExp('\\\$(\\($escapedKey\\)|$escapedKey\\b)'), value);
    });

    var argsWithInput = <String>[];
    for (var arg in args) {
      var newArg = arg;
      substitutions
          .forEach((regex, value) => newArg = newArg.replaceAll(regex, value));
      argsWithInput.add(newArg);
    }

    return argsWithInput;
  }

  ResourceProvider get resourceProvider => toolConfiguration.resourceProvider;

  p.Context get pathContext => resourceProvider.pathContext;
}
