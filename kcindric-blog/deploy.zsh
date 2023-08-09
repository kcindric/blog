#!/bin/zsh

# This line sets the commit message from the passed argument
commit_message=$1

# build hugo blog with theme defined in hugo.toml
hugo

# add, commit and push code
git add .
git commit -m $commit_message
git push origin main

# add, commit and push build output (website) from the submodule
cd public
git add .
git commit -m $commit_message
git push origin main

echo "blog deployed!"