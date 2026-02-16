defmodule Jido.Shell.AtomLeakTest do
  use Jido.Shell.Case, async: false

  alias Jido.Shell.Session

  test "dynamic workspace/session identifiers do not create unbounded atoms" do
    warmup_workspace = "atom_warmup_#{System.unique_integer([:positive])}"
    {:ok, warmup_session} = Session.start_with_vfs(warmup_workspace)
    :ok = Session.stop(warmup_session)
    :ok = Session.teardown_workspace(warmup_workspace)

    before_count = :erlang.system_info(:atom_count)

    Enum.each(1..25, fn _ ->
      workspace_id = "atom_ws_#{System.unique_integer([:positive])}"
      {:ok, session_id} = Session.start_with_vfs(workspace_id)
      :ok = Session.stop(session_id)
      :ok = Session.teardown_workspace(workspace_id)
    end)

    after_count = :erlang.system_info(:atom_count)

    assert after_count - before_count <= 3
  end
end
