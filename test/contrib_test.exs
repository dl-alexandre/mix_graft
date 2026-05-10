defmodule ContribTest do
  use ExUnit.Case
  doctest Contrib

  test "module loads" do
    assert Code.ensure_loaded?(Contrib)
  end
end
