package cmd

import (
	"github.com/hogelog/doko/pkg/search"

	"github.com/spf13/cobra"
)

var addCmd = &cobra.Command{
	Use:   "add",
	Short: "Add search index",
	Run: func(cmd *cobra.Command, args []string) {
		url := args[0]
		words := args[1:]
		client := search.NewClient()
		client.AddDocument(url, words)
	},
}

func init() {
	rootCmd.AddCommand(addCmd)
}
