#!/usr/bin/env bash
# Bring a ROS2 stack up and assert it reached a working state.
#
# This replaces the `timeout N; exit 124 == pass` pattern. Exit 124 says only that a
# process was still alive when a timer fired: a launch whose only node died on import
# passes it, because `ros2 launch` keeps running around the corpse. Every check here
# asserts something observable instead.
#
# The caller sources ROS and the workspace overlay first, then:
#
#   LAUNCH='ros2 launch fm_bringup sim.launch.py robot:=so101 sim_backend:=mock' \
#   EXPECT_NODES='/controller_manager /robot_state_publisher' \
#   EXPECT_CONTROLLERS='joint_state_broadcaster so101_arm_controller' \
#   EXPECT_TOPICS='/joint_states' \
#     ./ros2-smoke-assert.sh
#
# Two consumers share this file: .github/workflows/ros2-smoke.yml, for a repo whose
# smoke builds its own workspace, and a plain step in a repo that already built one
# and should not pay for a second build.
#
# Env:
#   LAUNCH              command that brings the stack up and keeps running (required)
#   EXPECT_NODES        node names that must appear in `ros2 node list`
#   EXPECT_CONTROLLERS  controllers that must reach state `active`
#   EXPECT_TOPICS       topics that must deliver a message inside the window
#   READY_TIMEOUT       seconds to wait for nodes + controllers (default 90)
#   TOPIC_TIMEOUT       seconds to wait for one message per topic (default 15)
#
# Not errexit: every assertion runs, and failures aggregate, so one red check still
# reports the state of the others.
set -uo pipefail

LAUNCH="${LAUNCH:?LAUNCH is required}"
EXPECT_NODES="${EXPECT_NODES:-}"
EXPECT_CONTROLLERS="${EXPECT_CONTROLLERS:-}"
EXPECT_TOPICS="${EXPECT_TOPICS:-}"
READY_TIMEOUT="${READY_TIMEOUT:-90}"
TOPIC_TIMEOUT="${TOPIC_TIMEOUT:-15}"

fails=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  fails=$((fails + 1))
}

main() {
  # A caller that asserts nothing gets a red run, not a green one. Without this the
  # script would silently accept the exact contract it exists to remove.
  if [ -z "${EXPECT_NODES}${EXPECT_CONTROLLERS}${EXPECT_TOPICS}" ]; then
    echo "FAIL: no EXPECT_NODES, EXPECT_CONTROLLERS, or EXPECT_TOPICS given."
    echo "A smoke that asserts nothing cannot fail, and must not merge."
    return 1
  fi

  # `ros2 control` comes from ros2controlcli, which the ROS base images do not ship.
  # Without this guard a missing CLI reads as "controller not active yet" and the run
  # fails with a misleading message.
  if [ -n "$EXPECT_CONTROLLERS" ] && ! ros2 control list_controllers --help >/dev/null 2>&1; then
    echo "FAIL: EXPECT_CONTROLLERS given but ros2controlcli is not installed."
    echo "Install ros-\${ROS_DISTRO}-ros2controlcli before running this."
    return 1
  fi

  echo "==> launching: $LAUNCH"
  bash -c "$LAUNCH" >/tmp/smoke.log 2>&1 &
  local launch_pid=$!

  # Nodes and controllers poll together: both answer "has the stack reached this
  # state yet", and one deadline covers the whole bring-up.
  local deadline=$((SECONDS + READY_TIMEOUT))
  local nodes_left="$EXPECT_NODES" controllers_left="$EXPECT_CONTROLLERS"
  local node_list ctrl_list still n c t
  while [ $SECONDS -lt $deadline ]; do
    # A launch that died takes its assertions with it — stop waiting on a stack that
    # is no longer coming up.
    if ! kill -0 "$launch_pid" 2>/dev/null; then
      echo "launch exited early (log below)"
      break
    fi
    if [ -n "$nodes_left" ]; then
      node_list="$(ros2 node list 2>/dev/null)"
      still=""
      for n in $nodes_left; do
        grep -qxF "$n" <<<"$node_list" || still="$still $n"
      done
      nodes_left="${still# }"
    fi
    if [ -n "$controllers_left" ]; then
      # Strip ANSI colour before matching. list_controllers colours the name and the
      # state unconditionally — not only on a tty — so the raw line begins with an
      # escape sequence rather than the controller name, and `^name` never matches:
      #
      #   ESC[92mjoint_state_broadcaster ESC[0m …  ESC[92mactiveESC[0m
      #
      # Every controller reported `active` and every assert still failed. The ANSI-C
      # quoted ESC keeps this working under BSD sed as well as GNU.
      ctrl_list="$(ros2 control list_controllers 2>/dev/null |
                   sed $'s/\033\\[[0-9;]*m//g')"
      still=""
      for c in $controllers_left; do
        # list_controllers prints `name[type/Class] state`. Anchor on the name
        # followed by a non-identifier character, and match `active` as a whole
        # word — an unanchored `.*active` also matches `inactive`.
        grep -qE "^${c}[^a-zA-Z0-9_].*[[:space:]]active([[:space:]]|$)" \
          <<<"$ctrl_list" || still="$still $c"
      done
      controllers_left="${still# }"
    fi
    [ -z "$nodes_left$controllers_left" ] && break
    sleep 2
  done

  for n in $EXPECT_NODES; do
    case " $nodes_left " in
      *" $n "*) fail "node $n never appeared in ros2 node list" ;;
      *) pass "node $n up" ;;
    esac
  done
  for c in $EXPECT_CONTROLLERS; do
    case " $controllers_left " in
      *" $c "*) fail "controller $c never reached active" ;;
      *) pass "controller $c active" ;;
    esac
  done

  # The assertion a silent stack cannot pass: a real message, on the wire, inside
  # the window.
  for t in $EXPECT_TOPICS; do
    if timeout "$TOPIC_TIMEOUT" ros2 topic echo --once "$t" >/tmp/topic.out 2>/dev/null &&
       [ -s /tmp/topic.out ]; then
      pass "topic $t published within ${TOPIC_TIMEOUT}s"
    else
      fail "topic $t published nothing within ${TOPIC_TIMEOUT}s"
    fi
  done

  # Capture the graph before teardown, while it still exists. A failure says which
  # assertion did not hold; this says what the stack actually looked like, which is
  # the difference between diagnosing in one run and guessing across several. Taken
  # only on failure — a green run does not need the noise.
  if [ "$fails" -ne 0 ]; then
    { echo "== ros2 node list =="
      ros2 node list 2>&1
      if [ -n "$EXPECT_CONTROLLERS" ]; then
        echo "== ros2 control list_controllers =="
        ros2 control list_controllers 2>&1
      fi
      echo "== ros2 topic list =="
      ros2 topic list 2>&1
    } >/tmp/smoke-state.txt
  fi

  # Bounded teardown: a plain `wait` blocks forever when a launch child ignores
  # SIGTERM, which hangs the job until the runner's own timeout.
  kill "$launch_pid" 2>/dev/null || true
  local _
  for _ in $(seq 1 15); do
    kill -0 "$launch_pid" 2>/dev/null || break
    sleep 1
  done
  kill -9 "$launch_pid" 2>/dev/null || true

  echo "==> smoke: ${fails} failure(s)"
  if [ "$fails" -ne 0 ]; then
    echo "==> graph at failure"
    cat /tmp/smoke-state.txt 2>/dev/null || echo "(not captured)"
    echo "==> launch log (last 60 lines)"
    tail -60 /tmp/smoke.log || true
  fi
  [ "$fails" -eq 0 ]
}

main "$@"
