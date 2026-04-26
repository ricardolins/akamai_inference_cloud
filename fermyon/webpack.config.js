const path = require("path");

module.exports = {
  entry: "./src/router.js",
  mode: "production",
  target: "web",
  resolve: {
    extensions: [".js"],
  },
  output: {
    filename: "router.js",
    path: path.resolve(__dirname, "dist"),
    library: { type: "commonjs2" },
  },
  optimization: {
    minimize: false,
  },
};
