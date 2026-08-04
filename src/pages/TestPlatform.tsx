import { useState } from "react";
import { PlatformSelector } from "@/components/engagement/PlatformSelector";
import { Card } from "@/components/ui/card";
import { Rocket } from "lucide-react";

export default function TestPlatform() {
  const [platform, setPlatform] = useState("instagram");
  return (
    <div className="min-h-screen bg-background p-8">
      <div className="max-w-3xl mx-auto space-y-6">
        <Card className="p-6">
          <label className="flex items-center gap-2 text-sm font-semibold text-foreground mb-4">
            <Rocket className="h-4 w-4 text-primary" /> Select Platform
          </label>
          <PlatformSelector selected={platform} onSelect={setPlatform} />
        </Card>
      </div>
    </div>
  );
}
