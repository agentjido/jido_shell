defmodule Kodo.E2ETest do
  @moduledoc """
  End-to-end integration tests for Kodo shell.

  These tests exercise complete user workflows through the shell,
  simulating real interactive usage patterns.
  """

  use ExUnit.Case, async: false

  alias Kodo.TestShell

  describe "basic shell operations" do
    test "pwd shows current directory" do
      shell = TestShell.start!()
      assert {:ok, "/"} = TestShell.run(shell, "pwd")
    end

    test "echo prints arguments" do
      shell = TestShell.start!()
      assert {:ok, "hello world"} = TestShell.run(shell, "echo hello world")
    end

    test "help lists available commands" do
      shell = TestShell.start!()
      {:ok, output} = TestShell.run(shell, "help")

      assert output =~ "echo"
      assert output =~ "pwd"
      assert output =~ "ls"
      assert output =~ "cd"
    end

    test "unknown command returns error" do
      shell = TestShell.start!()
      assert {:error, :unknown_command} = TestShell.run(shell, "notacommand")
    end

    test "empty command is handled gracefully" do
      shell = TestShell.start!()
      # Empty commands return :empty_command error
      result = TestShell.run(shell, "")
      assert result in [{:ok, ""}, {:error, :unknown_command}, {:error, :empty_command}]
    end
  end

  describe "directory navigation" do
    test "mkdir creates directory" do
      shell = TestShell.start!()

      assert {:ok, _} = TestShell.run(shell, "mkdir /projects")
      assert TestShell.exists?(shell, "/projects")
    end

    test "cd changes directory" do
      shell = TestShell.start!()

      TestShell.run!(shell, "mkdir /projects")
      TestShell.run!(shell, "cd /projects")

      assert TestShell.cwd(shell) == "/projects"
      assert {:ok, "/projects"} = TestShell.run(shell, "pwd")
    end

    test "cd to non-existent directory fails" do
      shell = TestShell.start!()

      {:error, error} = TestShell.run(shell, "cd /nonexistent")
      assert %Kodo.Error{} = error
    end

    test "cd with no args goes to root" do
      shell = TestShell.start!()

      TestShell.run!(shell, "mkdir /projects")
      TestShell.run!(shell, "cd /projects")
      assert TestShell.cwd(shell) == "/projects"

      TestShell.run!(shell, "cd")
      assert TestShell.cwd(shell) == "/"
    end

    test "cd with relative path" do
      shell = TestShell.start!()

      TestShell.run!(shell, "mkdir /projects")
      TestShell.run!(shell, "mkdir /projects/app")
      TestShell.run!(shell, "cd /projects")
      TestShell.run!(shell, "cd app")

      assert TestShell.cwd(shell) == "/projects/app"
    end

    test "cd .. navigates up" do
      shell = TestShell.start!()

      TestShell.run!(shell, "mkdir /projects")
      TestShell.run!(shell, "mkdir /projects/app")
      TestShell.run!(shell, "cd /projects/app")
      TestShell.run!(shell, "cd ..")

      assert TestShell.cwd(shell) == "/projects"
    end

    test "ls shows directory contents" do
      shell = TestShell.start!()

      TestShell.run!(shell, "mkdir /projects")
      TestShell.write_file!(shell, "/file1.txt", "a")
      TestShell.write_file!(shell, "/file2.txt", "b")

      {:ok, output} = TestShell.run(shell, "ls")

      assert output =~ "projects"
      assert output =~ "file1.txt"
      assert output =~ "file2.txt"
    end

    test "ls with path argument" do
      shell = TestShell.start!()

      TestShell.run!(shell, "mkdir /projects")
      TestShell.write_file!(shell, "/projects/app.ex", "code")

      {:ok, output} = TestShell.run(shell, "ls /projects")
      assert output =~ "app.ex"
    end
  end

  describe "file operations" do
    test "write creates file with content" do
      shell = TestShell.start!()

      TestShell.run!(shell, "write /test.txt Hello World")
      content = TestShell.read_file!(shell, "/test.txt")

      assert content == "Hello World"
    end

    test "cat displays file content" do
      shell = TestShell.start!()

      TestShell.write_file!(shell, "/greeting.txt", "Hello from Kodo!")
      {:ok, output} = TestShell.run(shell, "cat /greeting.txt")

      assert output == "Hello from Kodo!"
    end

    test "cat non-existent file shows error" do
      shell = TestShell.start!()
      {:error, _} = TestShell.run(shell, "cat /missing.txt")
    end

    test "rm deletes file" do
      shell = TestShell.start!()

      TestShell.write_file!(shell, "/delete_me.txt", "gone")
      assert TestShell.exists?(shell, "/delete_me.txt")

      TestShell.run!(shell, "rm /delete_me.txt")
      refute TestShell.exists?(shell, "/delete_me.txt")
    end

    test "cp copies file" do
      shell = TestShell.start!()

      TestShell.write_file!(shell, "/source.txt", "copy this")
      TestShell.run!(shell, "cp /source.txt /dest.txt")

      assert TestShell.read_file!(shell, "/dest.txt") == "copy this"
      # Source still exists
      assert TestShell.read_file!(shell, "/source.txt") == "copy this"
    end

    test "write and cat with relative paths" do
      shell = TestShell.start!()

      TestShell.run!(shell, "mkdir /projects")
      TestShell.run!(shell, "cd /projects")
      TestShell.run!(shell, "write notes.txt Remember this")

      {:ok, output} = TestShell.run(shell, "cat notes.txt")
      assert output == "Remember this"

      # Also accessible via absolute path
      assert TestShell.read_file!(shell, "/projects/notes.txt") == "Remember this"
    end
  end

  describe "environment variables" do
    test "env sets variable" do
      shell = TestShell.start!()

      TestShell.run!(shell, "env FOO=bar")
      env = TestShell.env(shell)

      assert env["FOO"] == "bar"
    end

    test "env displays variable" do
      shell = TestShell.start!()

      TestShell.run!(shell, "env MYVAR=myvalue")
      {:ok, output} = TestShell.run(shell, "env MYVAR")

      assert output == "MYVAR=myvalue"
    end

    test "env with no args shows all variables" do
      shell = TestShell.start!()

      TestShell.run!(shell, "env A=1")
      TestShell.run!(shell, "env B=2")

      {:ok, output} = TestShell.run(shell, "env")

      assert output =~ "A=1"
      assert output =~ "B=2"
    end

    test "env persists across commands" do
      shell = TestShell.start!()

      TestShell.run!(shell, "env PERSIST=yes")
      TestShell.run!(shell, "echo something")
      {:ok, output} = TestShell.run(shell, "env PERSIST")

      assert output == "PERSIST=yes"
    end
  end

  describe "command history" do
    test "commands are recorded in history" do
      shell = TestShell.start!()

      TestShell.run!(shell, "echo first")
      TestShell.run!(shell, "pwd")
      TestShell.run!(shell, "echo third")

      state = TestShell.state(shell)

      assert "echo first" in state.history
      assert "pwd" in state.history
      assert "echo third" in state.history
    end
  end

  describe "complex workflows" do
    test "project setup workflow" do
      shell = TestShell.start!()

      # Create project structure
      TestShell.run!(shell, "mkdir /myapp")
      TestShell.run!(shell, "cd /myapp")
      TestShell.run!(shell, "mkdir lib")
      TestShell.run!(shell, "mkdir test")

      # Create files
      TestShell.run!(shell, "write lib/main.ex defmodule Main do end")
      TestShell.run!(shell, "write test/main_test.exs defmodule MainTest do end")
      TestShell.run!(shell, "write README.md # MyApp")

      # Verify structure
      entries = TestShell.ls!(shell, "/myapp")
      assert "lib" in entries
      assert "test" in entries
      assert "README.md" in entries

      # Verify file contents
      assert TestShell.read_file!(shell, "/myapp/lib/main.ex") =~ "defmodule Main"
    end

    test "multi-directory navigation" do
      shell = TestShell.start!()

      # Setup structure
      TestShell.run!(shell, "mkdir /a")
      TestShell.run!(shell, "mkdir /a/b")
      TestShell.run!(shell, "mkdir /a/b/c")
      TestShell.write_file!(shell, "/a/b/c/deep.txt", "deep file")

      # Navigate down
      TestShell.run!(shell, "cd /a")
      TestShell.run!(shell, "cd b")
      TestShell.run!(shell, "cd c")

      {:ok, output} = TestShell.run(shell, "cat deep.txt")
      assert output == "deep file"

      # Navigate back up
      TestShell.run!(shell, "cd ..")
      assert TestShell.cwd(shell) == "/a/b"

      TestShell.run!(shell, "cd ..")
      assert TestShell.cwd(shell) == "/a"

      TestShell.run!(shell, "cd /")
      assert TestShell.cwd(shell) == "/"
    end

    test "file editing workflow" do
      shell = TestShell.start!()

      # Create initial file
      TestShell.run!(shell, "write /config.txt initial")
      assert TestShell.read_file!(shell, "/config.txt") == "initial"

      # Overwrite with new content
      TestShell.run!(shell, "write /config.txt updated")
      assert TestShell.read_file!(shell, "/config.txt") == "updated"
    end
  end

  describe "event streaming" do
    test "subscribe receives output events" do
      shell = TestShell.start!()
      TestShell.subscribe(shell)

      TestShell.run_async(shell, "echo streaming")

      events = TestShell.collect_events(shell)

      assert {:command_started, "echo streaming"} in events
      assert {:output, "streaming\n"} in events
      assert :command_done in events
    end

    test "cwd_changed event on cd" do
      shell = TestShell.start!()

      # Create target directory first (before subscribing)
      TestShell.run!(shell, "mkdir /target")

      # Now subscribe and run cd
      TestShell.subscribe(shell)
      TestShell.run_async(shell, "cd /target")
      events = TestShell.collect_events(shell)

      assert {:cwd_changed, "/target"} in events
    end

    test "error event for invalid command" do
      shell = TestShell.start!()
      TestShell.subscribe(shell)

      TestShell.run_async(shell, "invalidcmd")
      events = TestShell.collect_events(shell)

      assert Enum.any?(events, fn
               {:error, %Kodo.Error{code: {:shell, :unknown_command}}} -> true
               _ -> false
             end)
    end
  end

  describe "command cancellation" do
    test "cancel stops running command" do
      shell = TestShell.start!()
      TestShell.subscribe(shell)

      # Start a slow command
      TestShell.run_async(shell, "sleep 10")

      # Wait for it to start
      {:ok, _} = TestShell.await_event(shell, :command_started)

      # Cancel it
      TestShell.cancel(shell)

      # Should receive cancelled event
      {:ok, :command_cancelled} = TestShell.await_event(shell, :command_cancelled)
    end

    test "can run command after cancellation" do
      shell = TestShell.start!()
      TestShell.subscribe(shell)

      TestShell.run_async(shell, "sleep 10")
      {:ok, _} = TestShell.await_event(shell, :command_started)
      TestShell.cancel(shell)
      {:ok, _} = TestShell.await_event(shell, :command_cancelled)

      # Should be able to run new command
      assert {:ok, "recovered"} = TestShell.run(shell, "echo recovered")
    end
  end

  describe "concurrent access" do
    test "rejects command while busy" do
      shell = TestShell.start!()
      TestShell.subscribe(shell)

      # Start a slow command async (seq emits output slowly)
      TestShell.run_async(shell, "seq 10 1")

      # Wait for it to actually start
      {:ok, _} = TestShell.await_event(shell, :command_started)

      # Now try to run another command - should get busy error
      result = TestShell.run(shell, "echo hi", timeout: 100)
      assert result == {:error, :busy}

      # Wait for seq to complete
      TestShell.collect_events(shell, 15_000)
    end

    test "can run command after previous completes" do
      shell = TestShell.start!()

      # Run quick command
      assert {:ok, "first"} = TestShell.run(shell, "echo first")

      # Immediately run another
      assert {:ok, "second"} = TestShell.run(shell, "echo second")
    end
  end

  describe "session isolation" do
    test "separate shells are isolated" do
      shell1 = TestShell.start!()
      shell2 = TestShell.start!()

      # Create file in shell1
      TestShell.write_file!(shell1, "/only_in_shell1.txt", "private")

      # Should not exist in shell2
      refute TestShell.exists?(shell2, "/only_in_shell1.txt")

      # Each has own cwd
      TestShell.run!(shell1, "mkdir /dir1")
      TestShell.run!(shell1, "cd /dir1")
      TestShell.run!(shell2, "mkdir /dir2")
      TestShell.run!(shell2, "cd /dir2")

      assert TestShell.cwd(shell1) == "/dir1"
      assert TestShell.cwd(shell2) == "/dir2"
    end

    test "env vars are isolated between shells" do
      shell1 = TestShell.start!()
      shell2 = TestShell.start!()

      TestShell.run!(shell1, "env SHELL=1")
      TestShell.run!(shell2, "env SHELL=2")

      assert TestShell.env(shell1)["SHELL"] == "1"
      assert TestShell.env(shell2)["SHELL"] == "2"
    end
  end

  describe "initial state options" do
    test "starts with custom cwd" do
      shell = TestShell.start!(cwd: "/custom")
      assert TestShell.cwd(shell) == "/custom"
    end

    test "starts with custom env" do
      shell = TestShell.start!(env: %{"PRESET" => "value"})
      assert TestShell.env(shell)["PRESET"] == "value"
    end
  end

  describe "edge cases" do
    test "deeply nested directory creation" do
      shell = TestShell.start!()

      TestShell.run!(shell, "mkdir /a")
      TestShell.run!(shell, "mkdir /a/b")
      TestShell.run!(shell, "mkdir /a/b/c")
      TestShell.run!(shell, "mkdir /a/b/c/d")
      TestShell.run!(shell, "mkdir /a/b/c/d/e")

      assert TestShell.exists?(shell, "/a/b/c/d/e")
      TestShell.run!(shell, "cd /a/b/c/d/e")
      assert TestShell.cwd(shell) == "/a/b/c/d/e"
    end

    test "file with spaces in content" do
      shell = TestShell.start!()

      TestShell.run!(shell, "write /spaces.txt hello world with spaces")
      {:ok, output} = TestShell.run(shell, "cat /spaces.txt")

      assert output == "hello world with spaces"
    end

    test "empty directory listing" do
      shell = TestShell.start!()

      TestShell.run!(shell, "mkdir /empty")
      {:ok, output} = TestShell.run(shell, "ls /empty")

      # Empty or whitespace-only
      assert String.trim(output) == ""
    end

    test "overwrite existing file" do
      shell = TestShell.start!()

      TestShell.write_file!(shell, "/file.txt", "version 1")
      TestShell.write_file!(shell, "/file.txt", "version 2")

      assert TestShell.read_file!(shell, "/file.txt") == "version 2"
    end
  end
end
