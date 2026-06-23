##############################################################################
# Lorenzo Task Engine V0.3 — VCS + Verdi 仿真环境
#
# 用法速查:
#   make                          # 编译 + 仿真默认 TB (tb_lte_task_ctrl_top)
#   make TB=tb_lte_loop_nest_ctrl # 指定 TB
#   make comp                     # 仅编译
#   make sim                      # 仅仿真 (需先 comp)
#   make wave                     # 打开 Verdi 查看上一次 sim.fsdb
#   make run TB=tb_lte_tdt_decode # 编译+仿真+开波形 一键完成
#   make clean                    # 删除所有生成物
#   make help                     # 显示帮助
##############################################################################

#----------------------------------------------------------------------
# 工具路径
# 兼容两种常见环境变量设置方式:
#   a) VCS=vcs  (已在 PATH 中)
#   b) VCS=/install/dir  ($VCS 指向安装目录, 真正的二进制在 bin/ 下)
#----------------------------------------------------------------------
VCS    ?= vcs
VERDI  ?= verdi

# 若 $VCS / $VERDI 是目录, 自动补全 bin/ 子路径
VCS_BIN   := $(if $(wildcard $(VCS)/bin/vcs),$(VCS)/bin/vcs,$(VCS))
VERDI_BIN := $(if $(wildcard $(VERDI)/bin/verdi),$(VERDI)/bin/verdi,$(VERDI))

#----------------------------------------------------------------------
# 目录
#----------------------------------------------------------------------
ROOT   := $(shell cd .. && pwd)
RTL    := $(ROOT)/rtl
TBDIR  := $(ROOT)/tb
SIMDIR := $(ROOT)/sim

#----------------------------------------------------------------------
# 默认 TB (可通过 make TB=xxx 覆盖)
#----------------------------------------------------------------------
TB     ?= tb_lte_task_ctrl_top

#----------------------------------------------------------------------
# RTL 文件列表 (lte_pkg 必须最先)
#----------------------------------------------------------------------
RTL_FILES := \
    $(RTL)/lte_pkg.sv           \
    $(RTL)/lte_tdt_decode.sv    \
    $(RTL)/lte_task_context.sv  \
    $(RTL)/lte_loop_nest_ctrl.sv\
    $(RTL)/lte_boundary_ctrl.sv \
    $(RTL)/lte_task_dispatch.sv \
    $(RTL)/lte_error_ctrl.sv    \
    $(RTL)/lte_task_scoreboard.sv\
    $(RTL)/lte_csr.sv           \
    $(RTL)/lte_legacy_mux.sv    \
    $(RTL)/lte_task_ctrl_top.sv

TB_FILE   := $(TBDIR)/$(TB).sv
DUMP_FILE := $(SIMDIR)/dump_ctrl.sv

#----------------------------------------------------------------------
# VCS 编译选项
#----------------------------------------------------------------------
VCS_FLAGS := \
    -full64              \
    -sverilog            \
    -timescale=1ns/1ps   \
    -debug_access+all    \
    -kdb                 \
    +define+FSDB         \
    +define+TB_TOP=$(TB) \
    -notice              \
    -l comp.log

# 输出可执行文件名带 TB 名, 方便多 TB 并存
SIMV := simv_$(TB)

#----------------------------------------------------------------------
# 仿真选项
#----------------------------------------------------------------------
SIM_FLAGS := \
    -l sim_$(TB).log

#----------------------------------------------------------------------
# Verdi 选项
#----------------------------------------------------------------------
FSDB      := sim.fsdb
VERDI_FLAGS := \
    -sv                  \
    -ssf $(FSDB)         \
    -nologo

#----------------------------------------------------------------------
# 默认目标
#----------------------------------------------------------------------
.PHONY: all comp sim wave run clean help

all: comp sim

#----------------------------------------------------------------------
# 编译
# dump_ctrl 作为第二个 top, 注入 FSDB dump, 不修改任何 TB 文件
#----------------------------------------------------------------------
comp: $(RTL_FILES) $(TB_FILE) $(DUMP_FILE)
	@echo "========== [COMP] TB=$(TB) =========="
	$(VCS_BIN) $(VCS_FLAGS) \
	    $(RTL_FILES) $(TB_FILE) $(DUMP_FILE) \
	    -o $(SIMV)
	@echo "========== [COMP DONE] =========="

#----------------------------------------------------------------------
# 仿真
#----------------------------------------------------------------------
sim: $(SIMV)
	@echo "========== [SIM]  TB=$(TB) =========="
	./$(SIMV) $(SIM_FLAGS)
	@echo "========== [SIM DONE] =========="

#----------------------------------------------------------------------
# 编译 + 仿真 + 开波形 一键完成
#----------------------------------------------------------------------
run: comp sim wave

#----------------------------------------------------------------------
# 打开 Verdi
#----------------------------------------------------------------------
wave:
	@if [ ! -f $(FSDB) ]; then \
	    echo "[ERROR] $(FSDB) not found, run 'make sim' first"; exit 1; \
	fi
	@echo "========== [VERDI] opening $(FSDB) =========="
	$(VERDI_BIN) $(VERDI_FLAGS) \
	    -sv \
	    $(RTL_FILES) $(TB_FILE) &

#----------------------------------------------------------------------
# 清理
#----------------------------------------------------------------------
clean:
	@rm -rf simv_* csrc *.log *.fsdb *.vpd *.vcd \
	        DVEfiles *.key ucli.key novas.* verdiLog \
	        AN.DB *.db *.conf inter.vpd
	@echo "Cleaned."

#----------------------------------------------------------------------
# 帮助
#----------------------------------------------------------------------
help:
	@echo ""
	@echo "  make [TB=<name>]        编译 + 仿真"
	@echo "  make comp [TB=<name>]   仅编译"
	@echo "  make sim  [TB=<name>]   仅仿真 (需先 comp)"
	@echo "  make wave               打开 Verdi 查看 sim.fsdb"
	@echo "  make run  [TB=<name>]   编译 + 仿真 + 开波形"
	@echo "  make clean              删除所有生成物"
	@echo ""
	@echo "  可用 TB:"
	@ls $(TBDIR)/tb_*.sv | xargs -n1 basename | sed 's/\.sv//'
	@echo ""
