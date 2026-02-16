defmodule Jido.Shell.Session.StateTest do
  use Jido.Shell.Case, async: true

  alias Jido.Shell.Session.State

  describe "schema/0" do
    test "returns the Zoi schema" do
      schema = State.schema()
      assert is_struct(schema)
    end
  end

  describe "new/1" do
    test "creates state with required fields" do
      assert {:ok, state} = State.new(%{id: "sess-123", workspace_id: "my_workspace"})
      assert state.id == "sess-123"
      assert state.workspace_id == "my_workspace"
    end

    test "applies default values" do
      {:ok, state} = State.new(%{id: "s", workspace_id: "w"})
      assert state.cwd == "/"
      assert state.env == %{}
      assert state.history == []
      assert state.meta == %{}
      assert state.transports == MapSet.new()
      assert state.current_command == nil
    end

    test "allows overriding defaults" do
      {:ok, state} =
        State.new(%{
          id: "s",
          workspace_id: "w",
          cwd: "/home/user",
          env: %{"PATH" => "/bin"},
          history: ["pwd"],
          meta: %{user: "test"}
        })

      assert state.cwd == "/home/user"
      assert state.env == %{"PATH" => "/bin"}
      assert state.history == ["pwd"]
      assert state.meta == %{user: "test"}
    end

    test "returns error for missing required fields" do
      assert {:error, _} = State.new(%{})
      assert {:error, _} = State.new(%{id: "s"})
      assert {:error, _} = State.new(%{workspace_id: "w"})
    end

    test "rejects invalid workspace_id type" do
      assert {:error, errors} = State.new(%{id: "s", workspace_id: :not_a_string})
      assert length(errors) > 0
    end
  end

  describe "new!/1" do
    test "creates state successfully" do
      state = State.new!(%{id: "s", workspace_id: "w"})
      assert %State{} = state
    end

    test "raises on validation error" do
      assert_raise ArgumentError, fn ->
        State.new!(%{})
      end
    end
  end

  describe "add_transport/2" do
    test "adds a transport PID to the set" do
      {:ok, state} = State.new(%{id: "s", workspace_id: "w"})
      pid = self()

      state = State.add_transport(state, pid)

      assert MapSet.member?(state.transports, pid)
    end

    test "can add multiple transports" do
      {:ok, state} = State.new(%{id: "s", workspace_id: "w"})
      pid1 = spawn(fn -> :ok end)
      pid2 = spawn(fn -> :ok end)

      state =
        state
        |> State.add_transport(pid1)
        |> State.add_transport(pid2)

      assert MapSet.size(state.transports) == 2
    end
  end

  describe "remove_transport/2" do
    test "removes a transport PID from the set" do
      {:ok, state} = State.new(%{id: "s", workspace_id: "w"})
      pid = self()

      state =
        state
        |> State.add_transport(pid)
        |> State.remove_transport(pid)

      refute MapSet.member?(state.transports, pid)
    end

    test "handles removing non-existent transport" do
      {:ok, state} = State.new(%{id: "s", workspace_id: "w"})
      pid = self()

      state = State.remove_transport(state, pid)

      assert state.transports == MapSet.new()
    end
  end

  describe "add_to_history/2" do
    test "adds command to history" do
      {:ok, state} = State.new(%{id: "s", workspace_id: "w"})

      state = State.add_to_history(state, "ls -la")

      assert state.history == ["ls -la"]
    end

    test "prepends to history (most recent first)" do
      {:ok, state} = State.new(%{id: "s", workspace_id: "w"})

      state =
        state
        |> State.add_to_history("first")
        |> State.add_to_history("second")

      assert state.history == ["second", "first"]
    end
  end

  describe "set_cwd/2" do
    test "updates the current working directory" do
      {:ok, state} = State.new(%{id: "s", workspace_id: "w"})

      state = State.set_cwd(state, "/home/user/projects")

      assert state.cwd == "/home/user/projects"
    end
  end

  describe "set_current_command/2" do
    test "sets the current command" do
      {:ok, state} = State.new(%{id: "s", workspace_id: "w"})
      cmd_info = %{line: "ls", task: self(), ref: make_ref()}

      state = State.set_current_command(state, cmd_info)

      assert state.current_command == cmd_info
    end

    test "can set to nil" do
      {:ok, state} = State.new(%{id: "s", workspace_id: "w"})

      state =
        state
        |> State.set_current_command(%{line: "ls"})
        |> State.set_current_command(nil)

      assert state.current_command == nil
    end
  end

  describe "clear_current_command/1" do
    test "clears the current command" do
      {:ok, state} = State.new(%{id: "s", workspace_id: "w"})

      state =
        state
        |> State.set_current_command(%{line: "ls"})
        |> State.clear_current_command()

      assert state.current_command == nil
    end
  end

  describe "command_running?/1" do
    test "returns false when no command is running" do
      {:ok, state} = State.new(%{id: "s", workspace_id: "w"})
      refute State.command_running?(state)
    end

    test "returns true when a command is running" do
      {:ok, state} = State.new(%{id: "s", workspace_id: "w"})
      state = State.set_current_command(state, %{line: "ls"})
      assert State.command_running?(state)
    end
  end

  describe "struct" do
    test "can be pattern matched" do
      {:ok, state} = State.new(%{id: "s", workspace_id: "w"})
      assert %State{id: "s", workspace_id: "w"} = state
    end

    test "has the expected struct name" do
      {:ok, state} = State.new(%{id: "s", workspace_id: "w"})
      assert state.__struct__ == Jido.Shell.Session.State
    end
  end
end
