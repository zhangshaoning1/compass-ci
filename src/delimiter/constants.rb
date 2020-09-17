# SPDX-License-Identifier: MulanPSL-2.0+
# frozen_string_literal: true

START_PROCESS_COUNT = 10
GIT_MIRROR_HOST = ENV['GIT_MIRROR_HOST'] || '172.17.0.1'
MONITOR_HOST = ENV['MONITOR_HOST'] || '172.17.0.1'
MONITOR_PORT = ENV['MONITOR_PORT'] || '11310'
TMEP_GIT_BASE = '/c/public_git'
DELIMITER_TASK_QUEUE = 'delimiter'
BISECT_RUN_SCRIPT = "#{ENV['CCI_SRC']}/src/delimiter/find-commit/bisect_run_script.rb"
DELIMITER_TBOX_GROUP = 'vm-hi1620-2p8g--delimiter'
