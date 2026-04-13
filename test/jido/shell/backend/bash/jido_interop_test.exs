defmodule Jido.Shell.Backend.Bash.JidoInteropTest do
  use Jido.Shell.Case, async: false

  alias Jido.Shell.Backend.Bash.JidoInterop
  alias Jido.Shell.Backend.Bash.VfsAdapter
  alias Jido.Shell.VFS

  setup do
    VFS.init()
    workspace_id = "bash_interop_ws_#{System.unique_integer([:positive])}"
    fs_name = "bash_interop_fs_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Jido.VFS.Adapter.InMemory, {Jido.VFS.Adapter.InMemory, %Jido.VFS.Adapter.InMemory.Config{name: fs_name}}}
    )

    :ok = VFS.mount(workspace_id, "/", Jido.VFS.Adapter.InMemory, name: fs_name)

    Code.ensure_loaded!(JidoInterop)

    {:ok, session} =
      Bash.Session.new(
        filesystem: {VfsAdapter, %{workspace_id: workspace_id}},
        working_dir: "/",
        env: %{"JIDO_WORKSPACE_ID" => workspace_id},
        command_policy: [commands: :no_external],
        apis: [JidoInterop]
      )

    on_exit(fn ->
      if Process.alive?(session), do: Bash.Session.stop(session)
      VFS.unmount(workspace_id, "/")
    end)

    {:ok, session: session, workspace_id: workspace_id}
  end

  defp run!(session, script) do
    {_status, result, ^session} = Bash.run(script, session)

    {Bash.ExecutionResult.exit_code(result), Bash.ExecutionResult.stdout(result), Bash.ExecutionResult.stderr(result)}
  end

  describe "echo" do
    test "writes to stdout", %{session: session} do
      {0, stdout, _} = run!(session, "jido.echo hello world")
      assert stdout == "hello world\n"
    end
  end

  describe "pwd" do
    test "reflects the current working directory", %{session: session} do
      {0, stdout, _} = run!(session, "jido.pwd")
      assert stdout == "/\n"
    end
  end

  describe "write + cat round trip" do
    test "persists to the VFS and reads it back", %{session: session} do
      {0, _, _} = run!(session, "jido.write /note.txt 'hello from bash'")
      {0, stdout, _} = run!(session, "jido.cat /note.txt")
      assert stdout == "hello from bash"
    end
  end

  describe "ls" do
    test "lists directory contents", %{session: session, workspace_id: wid} do
      :ok = VFS.write_file(wid, "/a.txt", "")
      :ok = VFS.write_file(wid, "/b.txt", "")

      {0, stdout, _} = run!(session, "jido.ls /")
      assert stdout =~ "a.txt"
      assert stdout =~ "b.txt"
    end
  end

  describe "cd" do
    test "updates the outer session working directory", %{session: session, workspace_id: wid} do
      :ok = VFS.mkdir(wid, "/home")

      {0, _, _} = run!(session, "jido.cd /home")
      assert Bash.Session.get_cwd(session) == "/home"

      {0, stdout, _} = run!(session, "jido.pwd")
      assert stdout == "/home\n"
    end
  end

  describe "errors" do
    test "propagates file-not-found failures as non-zero exit", %{session: session} do
      {exit_code, _stdout, _stderr} = run!(session, "jido.cat /definitely-missing.txt")
      assert exit_code != 0
    end
  end

  describe "argument escaping" do
    test "passes arguments with whitespace through to the Jido command", %{session: session} do
      {0, stdout, _} = run!(session, ~s/jido.echo "hello world" "and again"/)
      assert stdout =~ "hello world"
      assert stdout =~ "and again"
    end
  end

  describe "dispatch/3 direct" do
    test "returns an error when JIDO_WORKSPACE_ID is not set" do
      state = %{variables: %{}, working_dir: "/"}
      assert {:error, msg} = JidoInterop.dispatch("echo", ["hi"], state)
      assert msg =~ "workspace not configured"
    end

    test "returns an error when session_state is malformed" do
      assert {:error, msg} = JidoInterop.dispatch("echo", [], %{})
      assert msg =~ "workspace not configured"
    end
  end

  describe "env round trip" do
    test "echoes an env var set through the outer session", %{session: session} do
      {:ok, _, ^session} = Bash.run("export MY_VAR=hello", session)
      {0, stdout, _} = run!(session, ~s/jido.echo "$MY_VAR"/)
      assert stdout == "hello\n"
    end
  end

  describe "remaining jido commands" do
    test "mkdir creates directories", %{session: session, workspace_id: wid} do
      {0, _, _} = run!(session, "jido.mkdir /mydir")
      assert VFS.exists?(wid, "/mydir")
    end

    test "rm removes files", %{session: session, workspace_id: wid} do
      :ok = VFS.write_file(wid, "/tmp.txt", "delete me")
      {0, _, _} = run!(session, "jido.rm /tmp.txt")
      refute VFS.exists?(wid, "/tmp.txt")
    end

    test "cp copies files", %{session: session, workspace_id: wid} do
      :ok = VFS.write_file(wid, "/orig.txt", "content")
      {0, _, _} = run!(session, "jido.cp /orig.txt /copy.txt")
      assert {:ok, "content"} = VFS.read_file(wid, "/copy.txt")
    end

    test "seq generates a sequence", %{session: session} do
      {0, stdout, _} = run!(session, "jido.seq 3")
      assert stdout =~ "1"
      assert stdout =~ "3"
    end

    test "sleep completes quickly for small durations", %{session: session} do
      {0, _, _} = run!(session, "jido.sleep 0")
    end

    test "env lists environment variables", %{session: session} do
      {0, stdout, _} = run!(session, "jido.env")
      assert is_binary(stdout)
    end
  end

  describe "build_state variants" do
    test "accepts workspace id as a plain string variable", %{workspace_id: wid} do
      state = %{variables: %{"JIDO_WORKSPACE_ID" => wid}, working_dir: "/"}
      assert {:ok, "\n"} = JidoInterop.dispatch("echo", [], state)
    end

    test "accepts workspace id as a %Bash.Variable{}", %{workspace_id: wid} do
      state = %{
        variables: %{"JIDO_WORKSPACE_ID" => Bash.Variable.new(wid)},
        working_dir: "/"
      }

      assert {:ok, output} = JidoInterop.dispatch("echo", ["hi"], state)
      assert output == "hi\n"
    end

    test "propagates environment variables from session_state", %{workspace_id: wid} do
      state = %{
        variables: %{
          "JIDO_WORKSPACE_ID" => Bash.Variable.new(wid),
          "MY_KEY" => Bash.Variable.new("my_value")
        },
        working_dir: "/"
      }

      assert {:ok, output} = JidoInterop.dispatch("env", [], state)
      assert output =~ "MY_KEY"
      assert output =~ "my_value"
    end

    test "returns an error when the underlying command fails", %{workspace_id: wid} do
      state = %{
        variables: %{"JIDO_WORKSPACE_ID" => Bash.Variable.new(wid)},
        working_dir: "/"
      }

      assert {:error, msg} = JidoInterop.dispatch("cat", ["/not-there.txt"], state)
      assert is_binary(msg)
    end

    test "handles a non-string non-struct variable value gracefully", %{workspace_id: wid} do
      state = %{variables: %{"JIDO_WORKSPACE_ID" => %{value: wid}}, working_dir: "/"}
      assert {:ok, "\n"} = JidoInterop.dispatch("echo", [], state)
    end

    test "ignores variables with non-binary values in env map", %{workspace_id: wid} do
      state = %{
        variables: %{
          "JIDO_WORKSPACE_ID" => Bash.Variable.new(wid),
          "BAD" => 42
        },
        working_dir: "/"
      }

      # Should succeed (BAD is silently dropped)
      assert result = JidoInterop.dispatch("echo", ["ok"], state)
      assert {:ok, "ok\n"} = result
    end
  end

  describe "write back from Jido command through bash session" do
    test "write command persists through interop bridge", %{session: session, workspace_id: wid} do
      {0, _, _} = run!(session, "jido.write /from_bash.txt 'bash wrote this'")
      assert {:ok, "bash wrote this"} = VFS.read_file(wid, "/from_bash.txt")
    end
  end

  describe "edge cases" do
    test "handles numeric variable values", %{workspace_id: wid} do
      state = %{
        variables: %{
          "JIDO_WORKSPACE_ID" => %{value: wid},
          "NUM" => 42
        },
        working_dir: "/"
      }

      # Should succeed — non-binary, non-struct variables are silently dropped
      result = JidoInterop.dispatch("echo", ["test"], state)
      assert {:ok, "test\n"} = result
    end

    test "variable_value returns empty for non-standard types", %{workspace_id: _wid} do
      # A non-struct, non-binary workspace id falls to the empty-string path.
      state = %{variables: %{"JIDO_WORKSPACE_ID" => {:tuple, "x"}}, working_dir: "/"}
      # The empty workspace_id causes State.new to fail validation, which
      # surfaces through `with` as a non-matching clause → unhandled raise.
      # This exercises the variable_value/1 wildcard clause.
      assert_raise WithClauseError, fn ->
        JidoInterop.dispatch("echo", ["hi"], state)
      end
    end
  end

  describe "stderr propagation through interop" do
    test "a Jido command error returns stderr message", %{session: session} do
      # cat on a missing file should produce a non-zero exit and stderr content
      {exit_code, _stdout, stderr} = run!(session, "jido.cat /definitely-missing-file.txt")
      assert exit_code != 0
      assert is_binary(stderr)
    end
  end

  describe "function shims in bash session" do
    test "function shim for echo works through prelude-style definition", %{session: session} do
      # Manually define the shim the way the prelude does it
      {:ok, _, ^session} = Bash.run("my_echo() { jido.echo \"$@\"; }", session)
      {0, stdout, _} = run!(session, "my_echo routed")
      assert stdout == "routed\n"
    end
  end

  describe "variables_to_env with plain string values" do
    test "accepts plain string variable values in env", %{workspace_id: wid} do
      # This exercises the `{key, value} when is_binary(value)` branch
      state = %{
        variables: %{
          "JIDO_WORKSPACE_ID" => Bash.Variable.new(wid),
          "PLAIN_STRING" => "raw_string_value"
        },
        working_dir: "/"
      }

      assert {:ok, output} = JidoInterop.dispatch("env", [], state)
      assert output =~ "PLAIN_STRING"
      assert output =~ "raw_string_value"
    end
  end
end
