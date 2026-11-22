import swift

from File file
where file.getRelativePath().matches("Sources/%") and file.getNumberOfLinesOfCode() > 0
select file.getRelativePath() as path
