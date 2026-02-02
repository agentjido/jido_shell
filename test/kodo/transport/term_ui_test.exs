defmodule Kodo.Transport.TermUITest do
  use Kodo.Case, async: false

  alias Kodo.Transport.TermUI, as: KodoTermUI

  describe "event_to_msg/2" do
    test "Ctrl+C when running cancels" do
      state = %KodoTermUI{command_running: true}
      event = TermUI.Event.key("c", modifiers: [:ctrl])

      assert {:msg, :cancel} = KodoTermUI.event_to_msg(event, state)
    end

    test "Ctrl+C when idle quits" do
      state = %KodoTermUI{command_running: false}
      event = TermUI.Event.key("c", modifiers: [:ctrl])

      assert {:msg, :quit} = KodoTermUI.event_to_msg(event, state)
    end

    test "Enter submits" do
      state = %KodoTermUI{}
      event = TermUI.Event.key(:enter)

      assert {:msg, :submit} = KodoTermUI.event_to_msg(event, state)
    end

    test "character input" do
      state = %KodoTermUI{}
      event = TermUI.Event.key("a")

      assert {:msg, {:char, "a"}} = KodoTermUI.event_to_msg(event, state)
    end

    test "up arrow for history" do
      state = %KodoTermUI{}
      event = TermUI.Event.key(:up)

      assert {:msg, :history_up} = KodoTermUI.event_to_msg(event, state)
    end

    test "unknown events are ignored" do
      state = %KodoTermUI{}
      event = TermUI.Event.custom(:unknown, "data")

      assert :ignore = KodoTermUI.event_to_msg(event, state)
    end
  end

  describe "update/2" do
    test "character input appends to input" do
      state = %KodoTermUI{input: "hel"}

      {new_state, commands} = KodoTermUI.update({:char, "l"}, state)

      assert new_state.input == "hell"
      assert commands == []
    end

    test "backspace removes last character" do
      state = %KodoTermUI{input: "hello"}

      {new_state, _} = KodoTermUI.update(:backspace, state)

      assert new_state.input == "hell"
    end

    test "submit with empty input does nothing" do
      state = %KodoTermUI{input: ""}

      {new_state, commands} = KodoTermUI.update(:submit, state)

      assert new_state == state
      assert commands == []
    end

    test "submit 'exit' quits" do
      state = %KodoTermUI{input: "exit"}

      {_state, commands} = KodoTermUI.update(:submit, state)

      assert commands == [:quit]
    end

    test "history up navigates history" do
      state = %KodoTermUI{history: ["ls", "pwd"], history_index: 0, input: ""}

      {new_state, _} = KodoTermUI.update(:history_up, state)

      assert new_state.history_index == 1
      assert new_state.input == "ls"
    end

    test "history up on empty history does nothing" do
      state = %KodoTermUI{history: [], history_index: 0}

      {new_state, _} = KodoTermUI.update(:history_up, state)

      assert new_state == state
    end

    test "history down navigates back" do
      state = %KodoTermUI{history: ["ls", "pwd"], history_index: 2, input: "pwd"}

      {new_state, _} = KodoTermUI.update(:history_down, state)

      assert new_state.history_index == 1
      assert new_state.input == "ls"
    end

    test "session output event appends lines" do
      state = %KodoTermUI{output_lines: ["line1"]}

      {new_state, _} = KodoTermUI.update({:session, {:output, "line2\nline3"}}, state)

      assert new_state.output_lines == ["line1", "line2", "line3"]
    end

    test "session command_done clears running flag" do
      state = %KodoTermUI{command_running: true}

      {new_state, _} = KodoTermUI.update({:session, :command_done}, state)

      assert new_state.command_running == false
    end

    test "session cwd_changed updates cwd" do
      state = %KodoTermUI{cwd: "/"}

      {new_state, _} = KodoTermUI.update({:session, {:cwd_changed, "/home"}}, state)

      assert new_state.cwd == "/home"
    end
  end

  describe "view/1" do
    test "renders without error" do
      state = %KodoTermUI{
        session_id: "test-id",
        workspace_id: :test,
        cwd: "/home",
        input: "ls",
        output_lines: ["file1.txt", "file2.txt"],
        command_running: false
      }

      # View should return a RenderNode struct
      result = KodoTermUI.view(state)
      assert %{type: :stack, children: children} = result
      assert length(children) == 4
    end
  end
end
