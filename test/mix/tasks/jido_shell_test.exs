defmodule Mix.Tasks.JidoShellTest do
  use ExUnit.Case, async: false
  import Mimic

  setup :set_mimic_from_context
  setup :verify_on_exit!

  test "runs interactive shell with default workspace" do
    copy(Jido.Shell.Transport.IEx)

    expect(Jido.Shell.Transport.IEx, :start, fn "default" ->
      :ok
    end)

    assert :ok = Mix.Tasks.JidoShell.run([])
  end

  test "runs interactive shell with explicit workspace" do
    copy(Jido.Shell.Transport.IEx)

    expect(Jido.Shell.Transport.IEx, :start, fn "my_workspace" ->
      :ok
    end)

    assert :ok = Mix.Tasks.JidoShell.run(["--workspace", "my_workspace"])
  end

  test "raises when transport returns an error" do
    copy(Jido.Shell.Transport.IEx)

    expect(Jido.Shell.Transport.IEx, :start, fn "default" ->
      {:error, Jido.Shell.Error.session(:not_found, %{})}
    end)

    assert_raise Mix.Error, ~r/failed to start shell/, fn ->
      Mix.Tasks.JidoShell.run([])
    end
  end

  test "raises when transport returns a non-structured error reason" do
    copy(Jido.Shell.Transport.IEx)

    expect(Jido.Shell.Transport.IEx, :start, fn "default" ->
      {:error, :boom}
    end)

    assert_raise Mix.Error, ~r/failed to start shell: :boom/, fn ->
      Mix.Tasks.JidoShell.run([])
    end
  end
end
