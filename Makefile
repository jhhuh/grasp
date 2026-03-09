# Grasp C-native bootstrap — zero Haskell
GHC_FLAGS = -no-hs-main -threaded -Wall

grasp_boot: cbits/grasp_rts.c cbits/grasp_boot.c cbits/grasp_rts.h
	ghc $(GHC_FLAGS) cbits/grasp_rts.c cbits/grasp_boot.c -o $@

layout_check: cbits/grasp_layout_check.c
	ghc $(GHC_FLAGS) $< -o $@

.PHONY: boot
boot: grasp_boot
	./grasp_boot

.PHONY: clean-boot
clean-boot:
	rm -f grasp_boot layout_check
	rm -f cbits/*.o cbits/*.hi
