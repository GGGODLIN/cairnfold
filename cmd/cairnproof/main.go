package main

import (
	"fmt"
	"os"

	"github.com/GGGODLIN/cairnfold/internal/proofgen"
)

func main() {
	if err := proofgen.RunBuildProofsCLI(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
