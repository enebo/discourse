import { registerUnbound } from "discourse-common/lib/helpers";

registerUnbound("format-score", function(score) {
  return (score || 0).toFixed(1);
});
