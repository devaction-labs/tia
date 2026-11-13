defmodule Tia.RecorderTest do
  use ExUnit.Case, async: true

  test "reject_ignored drops exact modules and name prefixes" do
    modules = [MyApp.Accounts, MyApp.Telemetry, MyApp.Telemetry.Poller, MyApp.PromEx, :my_erl]

    assert Tia.Recorder.reject_ignored(modules, []) == modules

    assert Tia.Recorder.reject_ignored(modules, [MyApp.Telemetry]) ==
             [MyApp.Accounts, MyApp.Telemetry.Poller, MyApp.PromEx, :my_erl]

    assert Tia.Recorder.reject_ignored(modules, ["MyApp.Telemetry", MyApp.PromEx, :my_erl]) ==
             [MyApp.Accounts]
  end
end
