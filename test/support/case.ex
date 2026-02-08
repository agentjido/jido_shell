defmodule Jido.Shell.Case do
  @moduledoc """
  Test case template for Jido.Shell tests.

  Provides isolated test environments with common setup.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Jido.Shell.Case
    end
  end

  setup do
    :ok
  end
end
