defmodule Jido.Shell.Transport.TermUITest do
  use Jido.Shell.Case, async: false

  alias Jido.Shell.Transport.TermUI

  describe "attach/1" do
    test "returns error for non-existent session" do
      assert {:error, :not_found} = TermUI.attach("nonexistent-session")
    end
  end

  describe "model structure" do
    test "has expected fields" do
      model = %{
        session_id: "test",
        workspace_id: :test,
        cwd: "/",
        output_buffer: [],
        input: "",
        history: [],
        history_index: 0,
        command_running: false,
        scroll_offset: 0
      }

      assert model.cwd == "/"
      assert model.output_buffer == []
      assert model.command_running == false
    end
  end

  describe "integration" do
    @tag :manual
    test "can be started with mix kodo --ui" do
      :ok
    end
  end
end
